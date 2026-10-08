//// The orchestrator's owner port: it serves the executor's callbacks from the
//// session's local services without blocking, and it reconciles
//// acknowledgements.

import client/escalate
import client/notice
import client/owner_services
import client/remote/owner_port
import client/remote/protocol.{type Key}
import core/clock
import core/json
import gleam/erlang/process
import gleam/option.{None}
import support/remote_fixtures as fixtures

fn key(n: Int) -> Key {
  protocol.Key(session: "s1", op: "op", step: "step", source_index: n)
}

fn port_over(
  services: owner_services.OwnerServices,
  settled: fn(Key) -> Bool,
  every_ms: Int,
) -> owner_port.Port {
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services:,
      clock: clock.fixed(at: 5000),
      settled:,
      reconcile_every_ms: every_ms,
    ))
    as "the port starts"
  port
}

pub fn every_callback_is_served_by_the_local_services_test() {
  let seen = process.new_subject()
  let services =
    owner_services.OwnerServices(
      ..fixtures.quiet_services(),
      escalate: fn(refused: escalate.Refused) {
        process.send(seen, refused.deadline_ms)
        escalate.Settle
      },
      notify: fn(strand, _work, text) {
        case strand {
          "main" -> Error("noticed: " <> text)
          _ -> Error("other strand")
        }
      },
    )
  let inbox = owner_port.inbox(port_over(services, fn(_key) { False }, 60_000))

  // The refusal's deadline was written on the executor's clock. The port
  // rebuilds it from the remaining time on its own clock.
  let run = fixtures.tool_run("call_1", 0)
  let refused =
    escalate.Refused(
      operation: run.operation,
      strand: "main",
      step_id: run.step_id,
      source_index: 0,
      call_id: "call_1",
      tool: "bash",
      denial: fixtures.denial(),
      arguments: run.arguments,
      deadline_ms: 1_000_000,
    )
  assert process.call(inbox, 2000, protocol.Escalate(refused, 59_000, _))
    == escalate.Settle
  assert process.receive(seen, 1000) == Ok(5000 + 59_000)

  // Facts, notices, holds and capabilities go through the same record.
  assert process.call(inbox, 2000, protocol.FactGet("job/1", _)) == Ok(None)
  assert process.call(inbox, 2000, protocol.FactPutBlind("job/1", json.Null, _))
    == Ok(Nil)
  assert process.call(inbox, 2000, protocol.Notify(
      "main",
      notice.Job(id: "1"),
      "done",
      _,
    ))
    == Error("noticed: done")
  let assert Error(denial) =
    process.call(inbox, 2000, protocol.Capability(fixtures.capability_call(), _))
  assert denial.code == "unsupported_cap"
}

pub fn a_parked_request_does_not_block_the_port_test() {
  let gate = fixtures.probe(fixtures.Held)
  let services =
    owner_services.OwnerServices(
      ..fixtures.quiet_services(),
      escalate: fn(_refused) {
        process.call(gate.subject, 10_000, fixtures.Wait)
        escalate.Settle
      },
    )
  let inbox = owner_port.inbox(port_over(services, fn(_key) { False }, 60_000))
  let run = fixtures.tool_run("call_1", 0)
  let parked = process.new_subject()
  process.send(
    inbox,
    protocol.Escalate(
      escalate.Refused(
        operation: run.operation,
        strand: "main",
        step_id: run.step_id,
        source_index: 0,
        call_id: "call_1",
        tool: "bash",
        denial: fixtures.denial(),
        arguments: run.arguments,
        deadline_ms: 0,
      ),
      60_000,
      parked,
    ),
  )

  // A second request is answered while the first is still parked.
  assert process.call(inbox, 2000, protocol.FactGet("job/1", _)) == Ok(None)
  assert process.receive(parked, 50) == Error(Nil)

  // Releasing the question lets its answer through.
  fixtures.release(gate)
  assert process.receive(parked, 2000) == Ok(escalate.Settle)
}

pub fn a_parked_request_ends_with_its_requester_test() {
  let started = process.new_subject()
  let finished = process.new_subject()
  let services =
    owner_services.OwnerServices(
      ..fixtures.quiet_services(),
      escalate: fn(_refused) {
        process.send(started, process.self())
        process.sleep(30_000)
        process.send(finished, Nil)
        escalate.Settle
      },
    )
  let inbox = owner_port.inbox(port_over(services, fn(_key) { False }, 60_000))
  let run = fixtures.tool_run("call_1", 0)

  // The executor-side call is a process that dies while its question is parked.
  let requester =
    process.spawn_unlinked(fn() {
      let reply = process.new_subject()
      process.send(
        inbox,
        protocol.Escalate(
          escalate.Refused(
            operation: run.operation,
            strand: "main",
            step_id: run.step_id,
            source_index: 0,
            call_id: "call_1",
            tool: "bash",
            denial: fixtures.denial(),
            arguments: run.arguments,
            deadline_ms: 0,
          ),
          60_000,
          reply,
        ),
      )
      process.sleep_forever()
    })
  let assert Ok(worker) = process.receive(started, 2000)
  process.kill(requester)

  // The worker serving the dead requester is killed, not left parked.
  assert fixtures.eventually(fn() { !process.is_alive(worker) })
  assert process.receive(finished, 50) == Error(Nil)
}

pub fn an_attach_acknowledges_only_the_settled_keys_test() {
  let acked = fixtures.marks()
  let port =
    port_over(
      fixtures.quiet_services(),
      fn(candidate) { candidate == key(0) || candidate == key(2) },
      60_000,
    )
  let link =
    owner_port.HostLink(list: fn() { Error("not asked") }, ack: fn(candidate) {
      fixtures.mark(acked, candidate)
    })

  // Both a stored result and a lost one are acknowledged once the orchestrator
  // holds the call's result; a call still in flight is left alone.
  owner_port.bind(
    port,
    link,
    protocol.Unacked(terminal: [key(0), key(1)], unknown: [key(2)]),
  )
  assert fixtures.eventually(fn() { fixtures.marked(acked) == [key(0), key(2)] })
  process.sleep(50)
  assert fixtures.marked(acked) == [key(0), key(2)]
}

pub fn the_timer_lists_again_and_acknowledges_what_settled_since_test() {
  let acked = fixtures.marks()
  let settled = fixtures.marks()
  let port =
    port_over(
      fixtures.quiet_services(),
      fn(candidate) { fixtures.is_marked(settled, candidate) },
      30,
    )
  let link =
    owner_port.HostLink(
      list: fn() { Ok(protocol.Unacked(terminal: [key(7)], unknown: [])) },
      ack: fn(candidate) { fixtures.mark(acked, candidate) },
    )

  // The attach reported nothing, and the host lists key 7 on the timer. It is
  // not settled yet, so it is not acknowledged.
  owner_port.bind(port, link, protocol.Unacked(terminal: [], unknown: []))
  process.sleep(150)
  assert fixtures.marked(acked) == []

  // A lost acknowledgement is found again once the result is staged.
  fixtures.mark(settled, key(7))
  assert fixtures.eventually(fn() { fixtures.marked(acked) != [] })
}
