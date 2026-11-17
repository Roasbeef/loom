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
////
//// The wire 5 tests (protocol-change/117) hold the link to the value bound on
//// what it receives, on an outcome it fetches and on what it sends, refuse a
//// tunnel event the link never asked for, and check that a welcome of another
//// wire version is refused in words that name both wire versions.
////
//// The tunnel tests (protocol-change/117) drive a session's clearing function
//// through the link's door while the hand-driven executor answers, or forges:
//// events for an id never issued, for a run, for a call still clearing, a
//// second `cleared`, output past the limit, a late `cleared` and a second
//// settlement. Every ordering of the proposal's table ends as it says, a
//// dropped connection sends no tunnelled call again, and each of the three
//// ways a caller gives a call up sends exactly one `cancel`.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import client/codemode as codemode_wiring
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
import client/workspace_policy
import codemode/satellite
import core/json
import core/message
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
import tools/agent
import tools/codemode as codemode_tool
import tools/tool

type Rig {
  Rig(
    listener: Listener,
    address: address.Address(protocol.HostMessage(RemoteCensus)),
    link: process.Pid,
    blobs: Subject(untrusted_bridge.BlobAsk),
    /// The link's tunnel door (protocol-change/117).
    door: process.Name(untrusted_link.Tunnel),
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
  let door = process.new_name("untrusted_link_door")
  let assert Ok(started) =
    untrusted_link.start_placing(untrusted_link.Config(
      executor: "pod",
      name:,
      door:,
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
    door:,
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
      door: process.new_name("untrusted_link_door"),
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
      door: process.new_name("untrusted_link_door"),
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

  // A piece for an id never minted is a violation.
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

pub fn a_fetch_place_freed_by_any_ending_goes_to_the_waiting_fetch_test() {
  let rig = start("fetch-waiting")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(first, _asker, first_answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let #(second, _asker, _answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_2", 0))
  let #(third, _asker, _answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_3", 0))
  let #(_bytes, size, digest) = encoding_of(effects.ToolFailed(reason: "no"))

  // Two fetches take the link's places; the third waits.
  rig.send(stream, untrusted_wire.Oversized(id: first, size:, digest:))
  let #(_piece, _at) = piece_request(stream)
  rig.send(stream, untrusted_wire.Oversized(id: second, size:, digest:))
  let #(_piece, _at) = piece_request(stream)
  rig.send(stream, untrusted_wire.Oversized(id: third, size:, digest:))
  assert rig.next_raw(stream, 300) == Error("silent")

  // The first ends in a way other than its fetch: the executor answers it
  // whole. Its place goes to the waiting fetch at once.
  let outcome = effects.ToolFailed(reason: "whole after all")
  rig.send(
    stream,
    untrusted_wire.Response(
      id: first,
      response: untrusted_wire.RunAnswered(protocol.RunFinished(outcome)),
    ),
  )
  assert process.receive(first_answers, 5000)
    == Ok(protocol.RunFinished(outcome))
  let assert Ok(untrusted_codec.RequestEnvelope(body:, ..)) = rig.next(stream)
    as "the waiting fetch asks for its first piece"
  let assert Ok(untrusted_wire.OutcomePieceRequest(key:, offset: 0)) =
    untrusted_codec.decode_request(body)
    as "it is the third call's piece"
  assert key == protocol.key_of("s1", fixtures.tool_run("call_3", 0))
  stop(rig)
}

pub fn a_request_larger_than_a_frame_is_refused_and_not_kept_test() {
  let rig = start("request-too-large")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let run =
    effects.ToolRun(
      ..fixtures.tool_run("call_1", 0),
      arguments: json.String(string.repeat("a", untrusted_wire.max_frame_bytes)),
    )

  // Kept, it would close the connection on every send and every reconnect.
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Run(
      key: protocol.key_of("s1", run),
      incarnation: 0,
      token: <<"token":utf8>>,
      run:,
      authority: fixtures.authority(),
      reply:,
    ),
  )
  let assert Ok(protocol.RunRefused(protocol.Invalid(_reason))) =
    process.receive(reply, 5000)
    as "the run is refused, not sent"
  assert rig.next_raw(stream, 300) == Error("silent")
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

pub fn a_run_or_start_for_a_session_with_no_binding_is_refused_and_never_sent_test() {
  let rig = start("run-unbound")
  let run = fixtures.tool_run("call_1", 0)
  let run_reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Run(
      key: protocol.key_of("s1", run),
      incarnation: 0,
      token: <<"token":utf8>>,
      run:,
      authority: fixtures.authority(),
      reply: run_reply,
    ),
  )

  // The refusal is the one an executor's host gives a scope it holds no plane
  // for, so a surface attaches again.
  let assert Ok(protocol.RunRefused(protocol.NoPlane(..))) =
    process.receive(run_reply, 2000)
    as "a run for a session with no binding is answered NoPlane"
  let start_reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.StartExecution(
      key: fixtures.execution_key("s1", "e1"),
      incarnation: 0,
      token: <<"token":utf8>>,
      terms: fixtures.execution_terms(),
      remaining_ms: 60_000,
      reply: start_reply,
    ),
  )
  let assert Ok(protocol.ExecutionRefused(protocol.NoPlane(..))) =
    process.receive(start_reply, 2000)
    as "a start for a session with no binding is answered NoPlane"

  // Messages that start no work go through for the same session, and they are
  // the first frames the executor reads: neither refused message was sent.
  let unacked_reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.ListUnacked(session: "s1", reply: unacked_reply),
  )
  let query_reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Query(key: protocol.key_of("s1", run), reply: query_reply),
  )
  let stream = rig.greeted(rig.listener)
  let assert Ok(untrusted_codec.RequestEnvelope(body: first, ..)) =
    rig.next(stream)
    as "the listing arrives"
  let assert Ok(untrusted_codec.RequestEnvelope(body: second, ..)) =
    rig.next(stream)
    as "the query arrives"
  assert untrusted_codec.decode_request(first)
    == Ok(untrusted_wire.ListUnackedRequest("s1"))
  assert untrusted_codec.decode_request(second)
    == Ok(untrusted_wire.QueryRequest(protocol.key_of("s1", run)))
  stop(rig)
}

pub fn a_run_after_the_session_attaches_is_sent_not_refused_test() {
  let rig = start("run-bound")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let run = fixtures.tool_run("call_1", 0)

  // The attach minted the binding, so the same run is carried.
  let #(_id, _asker, answers) = run_in_flight(rig, stream, "s1", run)
  assert process.receive(answers, 300) == Error(Nil)
  stop(rig)
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

// An owner port that answers every launch and reports the budget it was
// handed.
fn budget_port() -> #(Subject(protocol.OwnerMessage), Subject(Int)) {
  let budgets = process.new_subject()
  let handed = process.new_subject()
  process.spawn(fn() {
    let inbox = process.new_subject()
    process.send(handed, inbox)
    budget_loop(inbox, budgets)
  })
  let assert Ok(inbox) = process.receive(handed, 1000) as "the port starts"
  #(inbox, budgets)
}

fn budget_loop(
  inbox: Subject(protocol.OwnerMessage),
  budgets: Subject(Int),
) -> Nil {
  case process.receive_forever(inbox) {
    protocol.LaunchExecution(terms:, reply:) -> {
      process.send(budgets, terms.within_ms)
      process.send(reply, Ok(json.String("exec-1")))
    }
    _other -> Nil
  }
  budget_loop(inbox, budgets)
}

pub fn a_launch_budget_beyond_the_orchestrators_ceiling_is_clamped_test() {
  let rig = start("launch-budget")
  let #(port, budgets) = budget_port()
  let Attached(stream:, binding:) = attach(rig, "s1", port, None)
  let #(_id, _asker, _answers) =
    run_in_flight(rig, stream, "s1", code_mode_run("call_1", 0))

  // The executor's own clamp is the attacker's: a budget of thirty years
  // would keep the program's record, and its window to the owner, open.
  let launch =
    untrusted_wire.LaunchExecutionCall(
      owner_services.ExecutionTerms(
        ..fixtures.execution_terms(),
        within_ms: 1_000_000_000_000,
      ),
    )
  assert called(stream, binding, 1, launch)
    == untrusted_wire.LaunchAnswered(Ok(json.String("exec-1")))
  assert process.receive(budgets, 2000) == Ok(codemode_wiring.max_within_ms)

  // An honest budget under the ceiling reaches the owner as it was sent.
  assert called(
      stream,
      binding,
      2,
      untrusted_wire.LaunchExecutionCall(fixtures.execution_terms()),
    )
    == untrusted_wire.LaunchAnswered(Ok(json.String("exec-1")))
  assert process.receive(budgets, 2000)
    == Ok(fixtures.execution_terms().within_ms)
  stop(rig)
}

// --- wire 5: the value bound, the tunnel's frame and the version (117) -----------

/// A response frame for request `id` whose body is an array of `items` zeros,
/// so the frame holds `items + 4` values: the frame, its name, its id and the
/// array.
fn wide_response(id: Int, items: Int) -> BitArray {
  bit_array.from_string(
    "{\"frame\":\"response\",\"id\":"
    <> int.to_string(id)
    <> ",\"body\":["
    <> string.join(list.repeat("0", items), ",")
    <> "]}",
  )
}

// The link reads a response to a request it no longer holds without decoding
// its body, so the only thing a late response with a wide body can break is
// the value bound: at the bound it is dropped and the connection stays open,
// and one value past it is a violation that closes the connection.
pub fn a_frame_past_the_value_bound_closes_the_connection_test() {
  let rig = start("value-bound")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let run = fixtures.tool_run("call_1", 0)
  let #(id, _asker, answers) = run_in_flight(rig, stream, "s1", run)
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.RunAnswered(protocol.RunLost),
    ),
  )
  assert process.receive(answers, 5000) == Ok(protocol.RunLost)

  let at_bound = untrusted_wire.max_frame_values - 4
  rig.send_raw(stream, wide_response(id, at_bound))
  assert !rig.closed(stream, 3000)

  rig.send_raw(stream, wide_response(id, at_bound + 1))
  assert rig.closed(stream, 10_000)
  assert process.is_alive(rig.link)
  stop(rig)
}

/// An outcome whose result's details are an array of `items` zeros.
fn wide_outcome(items: Int) -> effects.ToolOutcome {
  effects.ToolCompleted(
    result: message.ToolResultMessage(
      tool_call_id: "call_1",
      tool_name: "bash",
      content: [],
      details: option.Some(json.Array(list.repeat(json.Int(0), items))),
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
    terminate: False,
  )
}

// An outcome is fetched in pieces whose bytes match their digest, so only its
// decoding can refuse it, and the value bound applies to it as to a frame:
// one that describes more values than a frame may hold is answered lost.
pub fn a_fetched_outcome_past_the_value_bound_is_lost_test() {
  let rig = start("outcome-value-bound")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let #(bytes, size, digest) =
    encoding_of(wide_outcome(untrusted_wire.max_frame_values))
  assert size < untrusted_wire.max_piece_bytes

  rig.send(stream, untrusted_wire.Oversized(id:, size:, digest:))
  let #(piece, at) = piece_request(stream)
  assert at == 0
  serve_piece(stream, piece, bytes, size, digest, 0)
  assert process.receive(answers, 10_000) == Ok(protocol.RunLost)
  assert !rig.closed(stream, 300)
  assert process.is_alive(rig.link)
  stop(rig)
}

// The link's own request is counted before it is kept: a run whose arguments
// hold more values than the executor's parse admits would close every
// connection it was sent on, so it is refused here and never sent.
pub fn a_request_of_more_values_than_the_bound_is_refused_and_not_kept_test() {
  let rig = start("request-too-wide")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let run =
    effects.ToolRun(
      ..fixtures.tool_run("call_1", 0),
      arguments: json.Array(list.repeat(
        json.Int(0),
        untrusted_wire.max_frame_values,
      )),
    )

  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Run(
      key: protocol.key_of("s1", run),
      incarnation: 0,
      token: <<"token":utf8>>,
      run:,
      authority: fixtures.authority(),
      reply:,
    ),
  )
  let assert Ok(protocol.RunRefused(protocol.Invalid(_reason))) =
    process.receive(reply, 10_000)
    as "the run is refused, not sent"
  assert rig.next_raw(stream, 300) == Error("silent")
  stop(rig)
}

// Request 1 is the attach, which is outstanding, so an event for it names a
// request of another kind than a tunnelled call: a frame an honest executor
// never sends.
pub fn a_call_event_for_an_attach_closes_the_connection_test() {
  let rig = start("call-event")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)

  rig.send(
    stream,
    untrusted_wire.CallEvent(
      call: 1,
      event: untrusted_wire.TunnelOutput(framing.Stdout, <<"forged">>),
    ),
  )
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)
  stop(rig)
}

/// Starts a link, sends an attach, and answers the link's `hello` with a
/// `welcome` of the given numbers. Answers what the attach was told.
fn welcomed_with(
  label: String,
  wire: Int,
  protocol_version: Int,
) -> Result(protocol.Attached(RemoteCensus), protocol.Refusal) {
  let rig = start(label)
  let #(port, _seen) = recording_port()
  let reply = attach_unread(rig.address, port)
  let stream = rig.accept(rig.listener)
  let assert Ok(untrusted_codec.HelloEnvelope(..)) = rig.next(stream)
    as "the link says hello"
  rig.send(stream, untrusted_wire.Welcome(wire:, protocol: protocol_version))
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the attach is answered"
  assert process.is_alive(rig.link)
  stop(rig)
  answer
}

// When only the wire differs, the refusal says so in both numbers instead of
// naming a protocol version the two sides share.
pub fn a_wire_only_version_mismatch_names_both_wire_versions_test() {
  let theirs = untrusted_wire.version - 1
  let assert Error(protocol.Unreachable(reason)) =
    welcomed_with("wire-mismatch", theirs, protocol.version)
    as "a wire-only mismatch is refused as unreachable"
  assert string.contains(reason, "wire version " <> int.to_string(theirs))
  assert string.contains(
    reason,
    "wire version " <> int.to_string(untrusted_wire.version),
  )

  // A protocol difference keeps 078's refusal.
  assert welcomed_with(
      "protocol-mismatch",
      untrusted_wire.version,
      protocol.version + 1,
    )
    == Error(protocol.VersionMismatch(supported: protocol.version + 1))
}

// --- the broker tunnel (117) -----------------------------------------------------

/// What a tunnelled call's asker tells the test: the clearing function's answer,
/// then every event the link delivers.
type Asked {
  Answered(answer: Result(tool.RunningCall, broker.Refusal))
  Heard(event: broker.CallEvent)
}

/// A spec a goal check would clear, with a per-stream output limit.
fn tunnel_spec(output_bytes: Int) -> broker.CallSpec {
  let base = workspace_policy.base_policy("/work")
  broker.CallSpec(
    op_id: fixtures.tool_run("check", 0).operation,
    step_id: "goal-check:1",
    base_policy: base,
    requirements: policy.SandboxPolicy(
      ..base,
      limits: policy.Limits(..base.limits, output_bytes:),
    ),
    grants: [],
    response: broker.RefuseNarrowed,
    demand: exec.PlatformEnforcement,
    argv: ["git", "status"],
    env: [],
    cwd: "/work",
    budget: budget.Budget(max_outstanding: 1, deadline_ms: 0),
  )
}

/// Clears `spec` for `session` from a process of its own through `clear`, and
/// forwards what it hears to the returned subject.
fn clear_from(
  clear: fn(broker.CallSpec, Subject(broker.CallEvent), Int) ->
    Result(tool.RunningCall, broker.Refusal),
  spec: broker.CallSpec,
  waiting: Int,
) -> #(process.Pid, Subject(Asked)) {
  let told = process.new_subject()
  let asker =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      process.send(told, Answered(clear(spec, events, waiting)))
      forwarding(events, told)
    })
  #(asker, told)
}

fn forwarding(events: Subject(broker.CallEvent), told: Subject(Asked)) -> Nil {
  process.send(told, Heard(process.receive_forever(events)))
  forwarding(events, told)
}

/// Clears from a fresh asker and reads the `clear_call` off the wire.
fn clearing(
  rig: Rig,
  stream: Stream,
  session: String,
  waiting: Int,
) -> #(Int, process.Pid, Subject(Asked)) {
  let #(asker, told) =
    clear_from(
      untrusted_link.tunnel_through(rig.door, session),
      tunnel_spec(64),
      waiting,
    )
  #(clear_request(stream), asker, told)
}

/// The id of the next frame, which must be a `clear_call`.
fn clear_request(stream: Stream) -> Int {
  let assert Ok(untrusted_codec.RequestEnvelope(id:, body:)) = rig.next(stream)
    as "the clearance arrives"
  let assert Ok(untrusted_wire.ClearCallRequest(spec:, waiting_ms:, ..)) =
    untrusted_codec.decode_request(body)
    as "it decodes as a clear_call"
  assert spec.argv == ["git", "status"]
  assert waiting_ms >= 1
  id
}

/// A call the executor has cleared, with its asker holding the running call.
fn running(
  rig: Rig,
  stream: Stream,
  session: String,
) -> #(Int, process.Pid, Subject(Asked), tool.RunningCall) {
  let #(id, asker, told) = clearing(rig, stream, session, 30_000)
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ClearedAnswered(Ok(Nil)),
    ),
  )
  let assert Ok(Answered(Ok(call))) = process.receive(told, 5000)
    as "the call cleared"
  #(id, asker, told, call)
}

fn lost() -> Asked {
  Heard(
    broker.CallSettled(broker.CallFailed(exec.ExecutionLost(exec.RelayDown))),
  )
}

fn settle(stream: Stream, id: Int) -> Nil {
  rig.send(
    stream,
    untrusted_wire.CallEvent(
      call: id,
      event: untrusted_wire.TunnelSettled(broker.CallExited(exited())),
    ),
  )
}

fn exited() -> exec.ExecResult {
  exec.ExecResult(
    code: 0,
    signal: 0,
    stdout_bytes: 5,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: [],
    degraded: False,
    wall_ms: 3,
    timed_out: False,
    cancelled: False,
  )
}

/// Every frame the executor reads within `within_ms`, decoded as far as its
/// envelope, until the connection is silent.
fn frames_within(
  stream: Stream,
  within_ms: Int,
) -> List(untrusted_codec.Envelope) {
  case rig.next_raw(stream, within_ms) {
    Ok(frame) ->
      case untrusted_codec.decode_envelope(frame) {
        Ok(envelope) -> [envelope, ..frames_within(stream, within_ms)]
        Error(_report) -> frames_within(stream, within_ms)
      }
    Error(_silent_or_closed) -> []
  }
}

fn cancels_of(frames: List(untrusted_codec.Envelope), id: Int) -> Int {
  list.count(frames, fn(envelope) {
    envelope == untrusted_codec.CancelEnvelope(id:)
  })
}

// The whole of an honest call: the executor clears it, streams output, and
// settles; the asker hears the output only at the settlement, as one chunk per
// stream with its byte count, then the settlement.
pub fn a_tunnelled_call_buffers_its_output_until_it_settles_test() {
  let rig = start("tunnel-honest")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, told, _call) = running(rig, stream, "s1")

  rig.send(
    stream,
    untrusted_wire.CallEvent(
      call: id,
      event: untrusted_wire.TunnelOutput(framing.Stdout, <<"hel">>),
    ),
  )
  rig.send(
    stream,
    untrusted_wire.CallEvent(
      call: id,
      event: untrusted_wire.TunnelOutput(framing.Stdout, <<"lo">>),
    ),
  )
  assert process.receive(told, 300) == Error(Nil)
  settle(stream, id)
  assert process.receive(told, 5000)
    == Ok(Heard(broker.CallOutput(framing.Stdout, <<"hello">>, 5, False)))
  assert process.receive(told, 5000)
    == Ok(Heard(broker.CallSettled(broker.CallExited(exited()))))

  // A second settlement crossed the removal and is dropped, and so is a late
  // `cleared`: the connection stays open.
  settle(stream, id)
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ClearedAnswered(Ok(Nil)),
    ),
  )
  assert !rig.closed(stream, 500)
  assert process.receive(told, 300) == Error(Nil)
  stop(rig)
}

// A refusal the executor answers reaches the asker, and the entry is gone.
pub fn a_refused_clearance_reaches_the_asker_test() {
  let rig = start("tunnel-refused")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, told) = clearing(rig, stream, "s1", 30_000)
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ClearedAnswered(Error(broker.OperationAborted)),
    ),
  )
  assert process.receive(told, 5000)
    == Ok(Answered(Error(broker.OperationAborted)))
  stop(rig)
}

/// Starts a rig with one running call, sends `forged` as the executor, and
/// checks that the connection closes, the link lives, and the running call's
/// asker hears that its call was lost.
fn forged_closes(label: String, forged: fn(Stream, Int) -> Nil) -> Nil {
  let rig = start(label)
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, told, _call) = running(rig, stream, "s1")

  forged(stream, id)
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)
  assert process.receive(told, 5000) == Ok(lost())
  stop(rig)
}

pub fn an_event_for_an_id_never_issued_closes_the_connection_test() {
  use stream, _id <- forged_closes("tunnel-never-issued")
  rig.send(
    stream,
    untrusted_wire.CallEvent(
      call: 9999,
      event: untrusted_wire.TunnelOutput(framing.Stdout, <<"forged">>),
    ),
  )
}

pub fn an_event_for_a_runs_id_closes_the_connection_test() {
  let rig = start("tunnel-run-id")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, told, _call) = running(rig, stream, "s1")
  let #(run_id, _run_asker, _answers) =
    run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  assert run_id != id

  rig.send(
    stream,
    untrusted_wire.CallEvent(
      call: run_id,
      event: untrusted_wire.TunnelSettled(broker.CallExited(exited())),
    ),
  )
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)
  assert process.receive(told, 5000) == Ok(lost())
  stop(rig)
}

pub fn an_event_for_a_call_still_clearing_closes_the_connection_test() {
  let rig = start("tunnel-clearing-event")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(_running_id, _asker, running_told, _call) = running(rig, stream, "s1")
  let #(clearing_id, _clearing_asker, clearing_told) =
    clearing(rig, stream, "s1", 30_000)

  rig.send(
    stream,
    untrusted_wire.CallEvent(
      call: clearing_id,
      event: untrusted_wire.TunnelOutput(framing.Stdout, <<"early">>),
    ),
  )
  assert rig.closed(stream, 5000)
  assert process.is_alive(rig.link)
  assert process.receive(running_told, 5000) == Ok(lost())
  assert process.receive(clearing_told, 5000)
    == Ok(Answered(Error(broker.BrokerUnavailable)))
  stop(rig)
}

pub fn a_second_cleared_for_a_running_call_closes_the_connection_test() {
  use stream, id <- forged_closes("tunnel-cleared-twice")
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ClearedAnswered(Ok(Nil)),
    ),
  )
}

pub fn output_past_the_limit_closes_the_connection_test() {
  use stream, id <- forged_closes("tunnel-past-limit")
  rig.send(
    stream,
    untrusted_wire.CallEvent(
      call: id,
      event: untrusted_wire.TunnelOutput(framing.Stderr, <<0:size({ 65 * 8 })>>),
    ),
  )
}

// A tunnelled call is sent on one connection at most: after a drop, its asker
// is told at once, and the next connection carries only what is re-sent for
// 109, never a `clear_call`.
pub fn a_dropped_connection_ends_tunnelled_calls_and_sends_none_again_test() {
  let rig = start("tunnel-dropped")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(_running_id, _asker, running_told, _call) = running(rig, stream, "s1")
  let #(_clearing_id, _clearing_asker, clearing_told) =
    clearing(rig, stream, "s1", 30_000)

  ffi_tls_stream.close(stream)
  assert process.receive(running_told, 5000) == Ok(lost())
  assert process.receive(clearing_told, 5000)
    == Ok(Answered(Error(broker.BrokerUnavailable)))

  // The binding makes the link dial again; it re-sends the attach and nothing
  // the tunnel sent.
  let again = rig.greeted(rig.listener)
  let resent = frames_within(again, 1000)
  assert resent != []
  assert list.all(resent, fn(envelope) {
    case envelope {
      untrusted_codec.RequestEnvelope(body:, ..) ->
        case untrusted_codec.decode_request(body) {
          Ok(untrusted_wire.ClearCallRequest(..)) -> False
          Ok(_other) | Error(_) -> True
        }
      _other -> True
    }
  })
  stop(rig)
}

pub fn the_death_of_a_tunnelled_calls_asker_sends_one_cancel_test() {
  let rig = start("tunnel-asker-dies")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, asker, _told, _call) = running(rig, stream, "s1")

  process.kill(asker)
  assert cancels_of(frames_within(stream, 1000), id) == 1
  stop(rig)
}

pub fn cancelling_a_tunnelled_call_settles_it_lost_and_sends_one_cancel_test() {
  let rig = start("tunnel-cancel")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, told, call) = running(rig, stream, "s1")

  call.cancel()
  call.cancel()
  assert process.receive(told, 5000) == Ok(lost())
  assert cancels_of(frames_within(stream, 1000), id) == 1

  // The executor's own settlement, crossing the cancel, is dropped.
  settle(stream, id)
  assert !rig.closed(stream, 500)
  assert process.receive(told, 300) == Error(Nil)
  stop(rig)
}

// The clearing function gives a call up while the link still holds it: the
// link forgets it and cancels it once, and its own clearance wait, which
// passes later, finds nothing to do.
pub fn a_withdrawn_clearance_sends_one_cancel_test() {
  let rig = start("tunnel-withdraw")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(_asker, told) =
    clear_from(
      untrusted_link.tunnel_waiting(rig.door, "s1", -2500),
      tunnel_spec(64),
      3000,
    )
  let id = clear_request(stream)

  assert process.receive(told, 5000)
    == Ok(Answered(Error(broker.BrokerUnavailable)))
  let frames = frames_within(stream, 3500)
  assert cancels_of(frames, id) == 1

  // A `cleared` for the withdrawn call crossed the removal and is dropped.
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ClearedAnswered(Ok(Nil)),
    ),
  )
  assert !rig.closed(stream, 500)
  stop(rig)
}

// The link's own clearance wait ends a call the executor never cleared.
pub fn a_clearance_wait_that_passes_refuses_and_sends_one_cancel_test() {
  let rig = start("tunnel-wait")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let #(id, _asker, told) = clearing(rig, stream, "s1", 300)

  assert process.receive(told, 5000)
    == Ok(Answered(Error(broker.BrokerUnavailable)))
  assert cancels_of(frames_within(stream, 1000), id) == 1
  stop(rig)
}

pub fn a_clear_with_no_connection_is_refused_at_once_test() {
  let rig = start("tunnel-no-connection")
  let clear = untrusted_link.tunnel_through(rig.door, "s1")
  let events = process.new_subject()
  assert clear(tunnel_spec(64), events, 30_000)
    == Error(broker.BrokerUnavailable)
  stop(rig)
}

pub fn a_clear_for_a_session_with_no_binding_is_refused_at_once_test() {
  let rig = start("tunnel-no-binding")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let clear = untrusted_link.tunnel_through(rig.door, "s2")
  let events = process.new_subject()

  assert clear(tunnel_spec(64), events, 30_000)
    == Error(broker.BrokerUnavailable)
  assert rig.next_raw(stream, 300) == Error("silent")
  stop(rig)
}

pub fn a_ninth_clear_on_one_binding_is_refused_at_once_test() {
  let rig = start("tunnel-ninth")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let _eight =
    list.map(list.repeat(Nil, 8), fn(_n) { clearing(rig, stream, "s1", 30_000) })

  let clear = untrusted_link.tunnel_through(rig.door, "s1")
  let events = process.new_subject()
  assert clear(tunnel_spec(64), events, 30_000)
    == Error(broker.BrokerUnavailable)
  assert rig.next_raw(stream, 300) == Error("silent")
  stop(rig)
}

// A spec whose argv passes the codec's limit would close the connection at the
// executor, so it is refused here and never sent; so is a spec with grants,
// and one whose output limit is past what the link holds.
pub fn a_spec_past_the_limits_is_refused_locally_and_not_sent_test() {
  let rig = start("tunnel-over-limit")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let clear = untrusted_link.tunnel_through(rig.door, "s1")
  let events = process.new_subject()
  let spec = tunnel_spec(64)

  let long =
    broker.CallSpec(
      ..spec,
      argv: list.repeat("x", untrusted_codec.max_call_argv + 1),
    )
  assert clear(long, events, 30_000) == Error(broker.BrokerUnavailable)
  let granted = broker.CallSpec(..spec, grants: [policy.GrantEnv("SECRET")])
  assert clear(granted, events, 30_000) == Error(broker.BrokerUnavailable)
  assert clear(tunnel_spec(2_000_000), events, 30_000)
    == Error(broker.BrokerUnavailable)
  assert rig.next_raw(stream, 300) == Error("silent")
  stop(rig)
}

// A door that dies after it was found, while a new link's door takes its
// name, may have let the `Clear` reach the new link. The clearing function
// then sends `Withdraw` to the name, after the `Clear`, so the new link drops
// a call nobody waits for. The first fake door takes the `Clear`, hands the
// name to a second fake and exits; the second records what reaches the name.
pub fn a_door_that_goes_down_is_followed_by_a_withdraw_test() {
  let door = process.new_name("untrusted_link_test_fake_door")
  let seen = process.new_subject()
  let ready = process.new_subject()
  let _first =
    process.spawn_unlinked(fn() {
      let assert Ok(Nil) = process.register(process.self(), door)
        as "the first door registers"
      process.send(ready, Nil)
      let message = process.receive_forever(process.named_subject(door))
      process.send(seen, untrusted_link.tunnel_shape(message))
      let assert Ok(Nil) = process.unregister(door) as "the first door leaves"
      let handed = process.new_subject()
      let _second =
        process.spawn_unlinked(fn() {
          let assert Ok(Nil) = process.register(process.self(), door)
            as "the second door registers"
          process.send(handed, Nil)
          recording_door(door, seen)
        })
      let assert Ok(Nil) = process.receive(handed, 1000)
        as "the second door holds the name"
      Nil
    })
  let assert Ok(Nil) = process.receive(ready, 1000) as "the first door is up"

  let clear = untrusted_link.tunnel_through(door, "s1")
  assert clear(tunnel_spec(64), process.new_subject(), 5000)
    == Error(broker.BrokerUnavailable)
  let assert Ok(#("clear", asked)) = process.receive(seen, 1000)
    as "the first door took the clearance"
  let assert Ok(#("withdraw", withdrawn)) = process.receive(seen, 1000)
    as "the withdraw reached the name's new holder"
  assert withdrawn == asked
}

fn recording_door(
  door: process.Name(untrusted_link.Tunnel),
  seen: Subject(#(String, Subject(Result(Nil, broker.Refusal)))),
) -> Nil {
  let message = process.receive_forever(process.named_subject(door))
  process.send(seen, untrusted_link.tunnel_shape(message))
  recording_door(door, seen)
}

// A clearance wait becomes a receive's timeout, which holds at most 2^32 - 1
// milliseconds: a wait at that bound is sent, and the caller's own receive does
// not raise; one past it is refused before anything is sent.
pub fn a_clearance_wait_is_held_to_a_receive_timeout_test() {
  let rig = start("tunnel-longest-wait")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let longest = untrusted_codec.max_call_wait_ms

  let #(_asker, told) =
    clear_from(
      untrusted_link.tunnel_through(rig.door, "s1"),
      tunnel_spec(64),
      longest,
    )
  let id = clear_request(stream)
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ClearedAnswered(Error(broker.OperationAborted)),
    ),
  )
  assert process.receive(told, 5000)
    == Ok(Answered(Error(broker.OperationAborted)))

  let #(_asker, told) =
    clear_from(
      untrusted_link.tunnel_through(rig.door, "s1"),
      tunnel_spec(64),
      longest + 1,
    )
  assert process.receive(told, 5000)
    == Ok(Answered(Error(broker.BrokerUnavailable)))
  assert rig.next_raw(stream, 300) == Error("silent")
  stop(rig)
}

// A deadline becomes a timer on the executor, for the time left to it, so the
// link carries one at 2^42 epoch milliseconds and refuses a later one before
// sending anything.
pub fn a_deadline_is_held_to_what_the_relays_timer_accepts_test() {
  let rig = start("tunnel-latest-deadline")
  let #(port, _seen) = recording_port()
  let Attached(stream:, ..) = attach(rig, "s1", port, None)
  let latest = untrusted_codec.max_call_ms
  assert latest == 4_398_046_511_104
  let at = fn(deadline_ms) {
    broker.CallSpec(
      ..tunnel_spec(64),
      budget: budget.Budget(max_outstanding: 1, deadline_ms:),
    )
  }

  let #(_asker, told) =
    clear_from(untrusted_link.tunnel_through(rig.door, "s1"), at(latest), 5000)
  let id = clear_request(stream)
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.ClearedAnswered(Error(broker.OperationAborted)),
    ),
  )
  assert process.receive(told, 5000)
    == Ok(Answered(Error(broker.OperationAborted)))

  let #(_asker, told) =
    clear_from(
      untrusted_link.tunnel_through(rig.door, "s1"),
      at(latest + 1),
      5000,
    )
  assert process.receive(told, 5000)
    == Ok(Answered(Error(broker.BrokerUnavailable)))
  assert rig.next_raw(stream, 300) == Error("silent")
  stop(rig)
}
