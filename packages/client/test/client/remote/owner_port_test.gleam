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
import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/option.{None}
import support/internal/ffi_proc
import support/remote_fixtures as fixtures
import tools/codemode as codemode_tool

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
      executions: owner_port.no_executions(),
      mcp: protocol.McpPlan(served: [], expected: []),
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
    owner_port.HostLink(
      list: fn() { Error("not asked") },
      ack: fn(candidate) { fixtures.mark(acked, candidate) },
      start: fn(_key, _terms, _remaining) { protocol.ExecutionLost },
      stop: fn(_key) { Nil },
      query: fn(_key) { Error("not asked") },
    )

  // Both a stored result and a lost one are acknowledged once the orchestrator
  // holds the call's result; a call still in flight is left alone.
  owner_port.bind(
    port,
    link,
    protocol.Unacked(
      terminal: [key(0), key(1)],
      unknown: [key(2)],
      executions: [],
    ),
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
      list: fn() {
        Ok(protocol.Unacked(terminal: [key(7)], unknown: [], executions: []))
      },
      ack: fn(candidate) { fixtures.mark(acked, candidate) },
      start: fn(_key, _terms, _remaining) { protocol.ExecutionLost },
      stop: fn(_key) { Nil },
      query: fn(_key) { Error("not asked") },
    )

  // The attach reported nothing, and the host lists key 7 on the timer. It is
  // not settled yet, so it is not acknowledged.
  owner_port.bind(
    port,
    link,
    protocol.Unacked(terminal: [], unknown: [], executions: []),
  )
  process.sleep(150)
  assert fixtures.marked(acked) == []

  // A lost acknowledgement is found again once the result is staged.
  fixtures.mark(settled, key(7))
  assert fixtures.eventually(fn() { fixtures.marked(acked) != [] })
}

// The executor's requester is a process on another node, so its pid is remote.
// A request from one must be served, or ended by the loss of its connection,
// without taking the port down: the port is the session's only channel for
// the executor's callbacks.
pub fn a_requester_on_another_node_does_not_take_the_port_down_test() {
  let services =
    owner_services.OwnerServices(
      ..fixtures.quiet_services(),
      escalate: fn(_refused) {
        process.sleep(30_000)
        escalate.Settle
      },
    )
  let inbox = owner_port.inbox(port_over(services, fn(_key) { False }, 60_000))
  let assert Ok(port) = process.subject_owner(inbox)
  let requester = ffi_proc.remote_pid()
  let reply = process.unsafely_create_subject(requester, dynamic.string("r"))
  process.send(inbox, protocol.FactGet("job/1", reply))
  let run = fixtures.tool_run("call_1", 0)
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
      process.unsafely_create_subject(requester, dynamic.string("e")),
    ),
  )

  // The scope that serves a request crashes into the port within microseconds
  // if it cannot watch its requester, so a port still serving after a pause
  // has watched it.
  process.sleep(300)
  assert process.is_alive(port)
  assert process.call(inbox, 2000, protocol.FactGet("job/1", _)) == Ok(None)
}

// --- background executions --------------------------------------------------------

fn port_with_executions(
  executions: owner_port.Executions,
  settled: fn(Key) -> Bool,
) -> owner_port.Port {
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 5000),
      settled:,
      reconcile_every_ms: 60_000,
      executions:,
      mcp: protocol.McpPlan(served: [], expected: []),
    ))
    as "the port starts"
  port
}

// A host link whose listing reports `running` as the executions still running,
// and that records every stop and acknowledgement it is asked to send.
fn listing_link(
  running: List(Key),
  stopped: process.Subject(Key),
  acked: process.Subject(Key),
) -> owner_port.HostLink {
  owner_port.HostLink(
    list: fn() {
      Ok(protocol.Unacked(terminal: [], unknown: [], executions: running))
    },
    ack: fn(key) { process.send(acked, key) },
    start: fn(_key, _terms, _remaining) { protocol.ExecutionLost },
    stop: fn(key) { process.send(stopped, key) },
    query: fn(_key) { Error("not asked") },
  )
}

pub fn a_launch_is_served_with_the_link_the_session_attached_through_test() {
  let used = process.new_subject()
  let executions =
    owner_port.Executions(
      ..owner_port.no_executions(),
      launch: fn(
        terms: owner_services.ExecutionTerms,
        link: owner_port.HostLink,
      ) {
        process.send(used, link.query(key(0)))
        Ok(json.String(terms.strand))
      },
    )
  let port = port_with_executions(executions, fn(_key) { False })
  let inbox = owner_port.inbox(port)
  let terms = fixtures.execution_terms()

  // Before any attach there is no link, and the launch is refused.
  let assert Error(_) =
    process.call(inbox, 2000, protocol.LaunchExecution(terms, _))
    as "a launch before the attach is refused"
  let link =
    owner_port.HostLink(
      ..listing_link([], process.new_subject(), process.new_subject()),
      query: fn(_key) { Error("the bound link") },
    )
  owner_port.bind(
    port,
    link,
    protocol.Unacked(terminal: [], unknown: [], executions: []),
  )
  assert process.call(inbox, 2000, protocol.LaunchExecution(terms, _))
    == Ok(json.String("main"))
  assert process.receive(used, 1000) == Ok(Error("the bound link"))
}

pub fn an_interaction_is_served_by_the_execution_service_test() {
  let executions =
    owner_port.Executions(
      ..owner_port.no_executions(),
      interact: fn(strand, handle, _interaction, within) {
        Ok(json.String(strand <> "/" <> handle <> "/" <> int.to_string(within)))
      },
    )
  let inbox =
    owner_port.inbox(port_with_executions(executions, fn(_key) { False }))
  assert process.call(inbox, 2000, protocol.InteractExecution(
      "main",
      "ab12",
      codemode_tool.Check,
      0,
      _,
    ))
    == Ok(json.String("main/ab12/0"))
}

pub fn the_reconciler_stops_running_programs_whose_record_closed_test() {
  let live = fixtures.execution_key("s1", "aa01")
  let closing = fixtures.execution_key("s1", "aa02")
  let closed = fixtures.execution_key("s1", "aa03")
  let executions =
    owner_port.Executions(..owner_port.no_executions(), standing: fn(found) {
      case found == live, found == closing {
        True, _ -> owner_port.RecordLive
        False, True -> owner_port.RecordClosing
        False, False -> owner_port.RecordClosed
      }
    })
  let port = port_with_executions(executions, fn(_key) { False })
  let stopped = process.new_subject()
  let acked = process.new_subject()
  owner_port.bind(
    port,
    listing_link([live, closing, closed], stopped, acked),
    protocol.Unacked(terminal: [], unknown: [], executions: [
      live,
      closing,
      closed,
    ]),
  )

  // The attach's own listing is reconciled at once: the two programs whose
  // record is no longer live are stopped, the live one is left running.
  let assert Ok(first) = process.receive(stopped, 2000)
  let assert Ok(second) = process.receive(stopped, 2000)
  assert [first, second] == [closing, closed]
  assert process.receive(stopped, 200) == Error(Nil)

  // A later pass sends the stops again, which is how a stop a partition lost
  // is repeated.
  owner_port.reconcile(port)
  let assert Ok(again) = process.receive(stopped, 2000)
  assert again == closing
}
