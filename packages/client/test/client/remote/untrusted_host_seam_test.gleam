//// A host module's calls over the untrusted link (protocol-change/111).
////
//// A host-defined code-mode module's functions are the host's own tools, and
//// each call returns to the orchestrator as a `capability` callback. The link
//// lets one through only under the binding it minted for the session's
//// attach, with an id it has not accepted before, and while a `code_mode`
//// call of that session with the same coordinates and strand is in flight.
//// Each test drives the real link over real TLS and plays a hostile executor
//// by hand, with an owner port that records what reaches it, so "refused"
//// means the owner never saw the call.
////
//// The helpers are this module's own rather than `untrusted_link_test`'s,
//// which keeps its private ones; they are the same few lines.

import client/internal/ffi_tls_stream.{type Listener, type Stream}
import client/owner_services
import client/remote/address
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import client/remote/untrusted_codec
import client/remote/untrusted_link
import client/remote/untrusted_wire
import codemode/satellite
import core/message
import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import runtime/effects.{type ToolRun}
import support/remote_fixtures as fixtures
import support/untrusted_rig as rig
import telemetry/log

type Rig {
  Rig(
    listener: Listener,
    address: address.Address(protocol.HostMessage(RemoteCensus)),
    link: process.Pid,
  )
}

// A link to a hand-driven executor listening on this machine.
fn start(label: String) -> Rig {
  let pair = rig.pair(label)
  let #(listener, port) = rig.listen(pair.executor, [pair.orchestrator_pin])
  let name = process.new_name("untrusted_host_seam_test")
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

// An owner port that records the capability calls it receives, by name, and
// answers each with a fixed success.
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
    protocol.Capability(call:, reply:) -> {
      process.send(seen, call.cap)
      process.send(
        reply,
        Error(satellite.CapDenial(code: "recorded", message: call.cap)),
      )
    }
    _other -> process.send(seen, "other")
  }
  record(inbox, seen)
}

// Whether the owner port saw nothing within a short wait.
fn unseen(seen: Subject(String)) -> Bool {
  process.receive(seen, 300) == Error(Nil)
}

// Sends an attach for `session` and, as the executor, reads it off the wire.
fn attach(
  rig: Rig,
  session: String,
  port: Subject(protocol.OwnerMessage),
  stream: option.Option(Stream),
) -> #(Stream, BitArray) {
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

  // A first attach greets a new connection; a later one shares it.
  let stream = case stream {
    option.Some(stream) -> stream
    None -> rig.greeted(rig.listener)
  }
  let assert Ok(untrusted_codec.RequestEnvelope(body:, ..)) = rig.next(stream)
    as "the attach arrives"
  let assert Ok(untrusted_wire.AttachRequest(binding:, ..)) =
    untrusted_codec.decode_request(body)
    as "it decodes as an attach"
  #(stream, binding)
}

// Sends a run from a process of its own and reads it off the wire; the
// process waits for the run's answer.
fn run_in_flight(
  rig: Rig,
  stream: Stream,
  session: String,
  run: ToolRun,
) -> Int {
  let address = rig.address
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
    process.receive_forever(reply)
  })
  let assert Ok(untrusted_codec.RequestEnvelope(id:, body:)) = rig.next(stream)
    as "the run arrives"
  let assert Ok(untrusted_wire.RunRequest(..)) =
    untrusted_codec.decode_request(body)
    as "it decodes as a run"
  id
}

// A `code_mode` call at the coordinates `fixtures.capability_call` names.
fn code_mode_run() -> ToolRun {
  let run = fixtures.tool_run("call_1", 0)
  effects.ToolRun(..run, call: message.ToolCall(..run.call, name: "code_mode"))
}

// A host module's call, made by the program of `code_mode_run`.
fn host_call() -> untrusted_wire.Callback {
  untrusted_wire.CapabilityCall(
    owner_services.OwnerCapCall(..fixtures.capability_call(), cap: "host.aegis"),
  )
}

// Sends a callback and reads the answer.
fn called(
  stream: Stream,
  binding: BitArray,
  id: Int,
  callback: untrusted_wire.Callback,
) -> untrusted_wire.Answer {
  rig.send(stream, untrusted_wire.Callback(binding:, id:, callback:))
  let assert Ok(untrusted_codec.AnswerEnvelope(body:, ..)) = rig.next(stream)
    as "the callback is answered"
  let assert option.Some(kind) = untrusted_wire.answer_kind(callback)
    as "the callback has an answer"
  let assert Ok(answer) = untrusted_codec.decode_answer(kind, body)
    as "the answer decodes"
  answer
}

// The answer the recording owner gives a call it saw.
fn reached(cap: String) -> untrusted_wire.Answer {
  untrusted_wire.CapabilityAnswered(
    Error(satellite.CapDenial(code: "recorded", message: cap)),
  )
}

pub fn a_host_call_with_no_program_running_is_refused_test() {
  let rig = start("host-idle")
  let #(port, seen) = recording_port()
  let #(stream, binding) = attach(rig, "s1", port, None)

  let assert untrusted_wire.CapabilityAnswered(Error(_refused)) =
    called(stream, binding, 1, host_call())
  assert unseen(seen)
  stop(rig)
}

pub fn a_host_call_under_another_tool_call_is_refused_test() {
  let rig = start("host-bash")
  let #(port, seen) = recording_port()
  let #(stream, binding) = attach(rig, "s1", port, None)

  // A `bash` call is in flight at the very coordinates and strand the host
  // call names. That is enough for an extension's owner-bound call, and not
  // for a host module's, which only a program makes.
  let _id = run_in_flight(rig, stream, "s1", fixtures.tool_run("call_1", 0))
  let assert untrusted_wire.CapabilityAnswered(Error(_refused)) =
    called(stream, binding, 1, host_call())
  assert unseen(seen)

  // The rule is the host family's alone: another owner-bound capability under
  // the same call still reaches the owner, as protocol-change/109 has it.
  assert called(
      stream,
      binding,
      2,
      untrusted_wire.CapabilityCall(fixtures.capability_call()),
    )
    == reached("strand.spawn")
  assert process.receive(seen, 2000) == Ok("strand.spawn")
  stop(rig)
}

pub fn a_host_call_reaches_the_owner_only_while_its_program_runs_test() {
  let rig = start("host-run")
  let #(port, seen) = recording_port()
  let #(stream, binding) = attach(rig, "s1", port, None)
  let id = run_in_flight(rig, stream, "s1", code_mode_run())

  // In flight, under the binding the link minted, with a fresh id.
  assert called(stream, binding, 1, host_call()) == reached("host.aegis")
  assert process.receive(seen, 2000) == Ok("host.aegis")

  // The `code_mode` call ends; the program's binding is still live, but a host
  // call now names no program, so it is refused. The response and the callback
  // travel on one stream and the link reads them in order, so no wait is
  // needed between them.
  let run = code_mode_run()
  rig.send(
    stream,
    untrusted_wire.Response(
      id:,
      response: untrusted_wire.RunAnswered(
        protocol.RunFinished(fixtures.expected_outcome(run)),
      ),
    ),
  )
  let assert untrusted_wire.CapabilityAnswered(Error(_refused)) =
    called(stream, binding, 2, host_call())
  assert unseen(seen)
  stop(rig)
}

pub fn a_replayed_host_call_is_refused_test() {
  let rig = start("host-replay")
  let #(port, seen) = recording_port()
  let #(stream, binding) = attach(rig, "s1", port, None)
  let _id = run_in_flight(rig, stream, "s1", code_mode_run())

  assert called(stream, binding, 4, host_call()) == reached("host.aegis")
  assert process.receive(seen, 2000) == Ok("host.aegis")

  // The same id again, and an older one, while the program still runs.
  let assert untrusted_wire.CapabilityAnswered(Error(_replayed)) =
    called(stream, binding, 4, host_call())
  let assert untrusted_wire.CapabilityAnswered(Error(_older)) =
    called(stream, binding, 2, host_call())
  assert unseen(seen)
  stop(rig)
}

pub fn a_host_call_through_a_retired_binding_is_refused_test() {
  let rig = start("host-retired")
  let #(first_port, first_seen) = recording_port()
  let #(second_port, second_seen) = recording_port()
  let #(stream, old) = attach(rig, "s1", first_port, None)

  // The session opens again with a new owner port, which retires the old
  // binding; the new open's program is running.
  let #(_stream, new) = attach(rig, "s1", second_port, option.Some(stream))
  assert new != old
  let _id = run_in_flight(rig, stream, "s1", code_mode_run())
  let assert untrusted_wire.CapabilityAnswered(Error(_retired)) =
    called(stream, old, 1, host_call())
  assert unseen(first_seen)
  assert unseen(second_seen)

  // Under the live binding the same call reaches the new owner.
  assert called(stream, new, 1, host_call()) == reached("host.aegis")
  assert process.receive(second_seen, 2000) == Ok("host.aegis")
  stop(rig)
}
