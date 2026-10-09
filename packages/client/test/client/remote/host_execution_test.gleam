//// Background executions on the executor's host, against a real ledger and a
//// fake workspace plane (protocol-change/078, the addendum on background code
//// mode).
////
//// An execution is a long-lived keyed call, so these tests read the same
//// number the tool-call tests read, how many times the fake program began, and
//// prove the rules that are the execution's own: a start is admitted once, a
//// stop for a closed record halts the program and aborts its broker step, a
//// stop that arrives first bars the key, an executor restart loses the
//// program and never replays it, a value too large for its reservation is
//// replaced by one that says so, and the host lists what is still running.

import client/owner_services
import client/remote/address.{type Address}
import client/remote/host
import client/remote/protocol.{
  type ExecutionAnswer, type HostMessage, type Key, type Refusal,
}
import core/json
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/string
import support/remote_fixtures as fixtures

type Rig {
  Rig(
    address: Address(HostMessage(String)),
    pid: Pid,
    probe: fixtures.Probe,
    path: String,
  )
}

fn token(n: Int) -> BitArray {
  bit_array.from_string("attach-token-" <> int.to_string(n))
}

fn rig(gate: fixtures.Gate) -> Rig {
  let probe = fixtures.probe(gate)
  let path = fixtures.scratch("host-execution") <> "/ledger.db"
  start(path, probe, fixtures.host_config(path, factory(probe)))
}

fn factory(probe: fixtures.Probe) -> host.PlaneFactory(String) {
  fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired)
}

fn start(
  path: String,
  probe: fixtures.Probe,
  config: host.Config(String),
) -> Rig {
  let assert Ok(started) = host.start(config) as "the host starts"
  Rig(address: started.data, pid: started.pid, probe:, path:)
}

fn stop(rig: Rig) -> Nil {
  process.unlink(rig.pid)
  process.kill(rig.pid)
}

fn attach(rig: Rig, attach_token: BitArray) -> protocol.Attached(String) {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Attach(
      version: protocol.version,
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      token: attach_token,
      owner_port: process.new_subject(),
      mcp: protocol.McpPlan(served: [], expected: []),
      reply:,
    ),
  )
  let assert Ok(Ok(attached)) = process.receive(reply, 5000)
    as "the host attaches the scope"
  attached
}

fn key(id: String) -> Key {
  fixtures.execution_key("s1", id)
}

fn start_execution(
  rig: Rig,
  id: String,
  attach_token: BitArray,
) -> Subject(ExecutionAnswer) {
  start_program(rig, id, attach_token, fixtures.execution_terms())
}

fn start_program(
  rig: Rig,
  id: String,
  attach_token: BitArray,
  terms: owner_services.ExecutionTerms,
) -> Subject(ExecutionAnswer) {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.StartExecution(
      key: key(id),
      incarnation: 0,
      token: attach_token,
      terms:,
      remaining_ms: 30_000,
      reply:,
    ),
  )
  reply
}

fn stop_execution(rig: Rig, id: String) -> Nil {
  address.deliver(
    rig.address,
    protocol.StopExecution(key: key(id), incarnation: 0),
  )
}

fn heard(reply: Subject(ExecutionAnswer)) -> ExecutionAnswer {
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers a start"
  answer
}

fn query(rig: Rig, id: String) -> Result(protocol.Lookup, Refusal) {
  let reply = process.new_subject()
  address.deliver(rig.address, protocol.Query(key(id), reply))
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers a query"
  answer
}

fn listed(rig: Rig) -> protocol.Unacked {
  let reply = process.new_subject()
  address.deliver(rig.address, protocol.ListUnacked("s1", reply))
  let assert Ok(Ok(unacked)) = process.receive(reply, 5000)
    as "the host answers a listing"
  unacked
}

fn step(id: String) -> String {
  protocol.execution_step_prefix <> id
}

fn ran(rig: Rig, id: String) -> Int {
  fixtures.run_count(rig.probe, step(id))
}

fn running(rig: Rig, id: String) -> Bool {
  fixtures.eventually(fn() { ran(rig, id) == 1 })
}

pub fn a_started_program_commits_its_value_before_the_answer_test() {
  let rig = rig(fixtures.Open)
  let _attached = attach(rig, token(1))

  let value = fixtures.expected_value(step("aa01"), 30_000)
  assert heard(start_execution(rig, "aa01", token(1)))
    == protocol.ExecutionFinished(value)
  assert query(rig, "aa01") == Ok(protocol.Executed(value))
  assert ran(rig, "aa01") == 1
  stop(rig)
}

pub fn a_resent_start_joins_the_live_program_and_runs_it_once_test() {
  let rig = rig(fixtures.Held)
  let _attached = attach(rig, token(1))
  let first = start_execution(rig, "aa02", token(1))
  assert running(rig, "aa02")
  assert listed(rig).executions == [key("aa02")]

  // The worker's re-send after a reconnect joins the program: one run, and both
  // sends hear the same value.
  let second = start_execution(rig, "aa02", token(1))
  fixtures.release(rig.probe)
  let value = fixtures.expected_value(step("aa02"), 30_000)
  assert heard(first) == protocol.ExecutionFinished(value)
  assert heard(second) == protocol.ExecutionFinished(value)
  assert ran(rig, "aa02") == 1
  assert listed(rig).executions == []
  stop(rig)
}

pub fn a_start_under_a_stale_token_is_refused_and_runs_nothing_test() {
  let rig = rig(fixtures.Open)
  let _first = attach(rig, token(1))
  let _second = attach(rig, token(2))

  assert heard(start_execution(rig, "aa03", token(1)))
    == protocol.ExecutionRefused(protocol.StaleToken)
  assert ran(rig, "aa03") == 0
  assert query(rig, "aa03") == Ok(protocol.Missing)
  stop(rig)
}

pub fn a_stop_halts_the_program_and_aborts_its_broker_step_test() {
  let rig = rig(fixtures.Held)
  let _attached = attach(rig, token(1))
  let waiting = start_execution(rig, "aa04", token(1))
  assert running(rig, "aa04")
  let assert [#(program, _step)] = fixtures.runs(rig.probe)

  stop_execution(rig, "aa04")
  assert heard(waiting) == protocol.ExecutionLost
  assert query(rig, "aa04") == Ok(protocol.Unknown)
  assert fixtures.eventually(fn() { !process.is_alive(program) })
  assert fixtures.eventually(fn() {
    fixtures.aborts(rig.probe) == [#(key("aa04").op, step("aa04"))]
  })

  // A start that comes later, such as a dead worker's, never runs it again.
  assert heard(start_execution(rig, "aa04", token(1))) == protocol.ExecutionLost
  assert ran(rig, "aa04") == 1
  stop(rig)
}

pub fn a_stop_that_arrives_first_bars_a_late_start_test() {
  let rig = rig(fixtures.Open)
  let _attached = attach(rig, token(1))

  // The record closed and its stop got to the host before the worker's start.
  stop_execution(rig, "aa05")
  assert fixtures.eventually(fn() { query(rig, "aa05") == Ok(protocol.Unknown) })
  assert heard(start_execution(rig, "aa05", token(1))) == protocol.ExecutionLost
  assert ran(rig, "aa05") == 0

  // The barred key is a lost row the reconciler acknowledges like any other.
  assert listed(rig).unknown == [key("aa05")]
  stop(rig)
}

pub fn a_stop_for_a_finished_program_changes_nothing_test() {
  let rig = rig(fixtures.Open)
  let _attached = attach(rig, token(1))
  let value = fixtures.expected_value(step("aa06"), 30_000)
  assert heard(start_execution(rig, "aa06", token(1)))
    == protocol.ExecutionFinished(value)

  stop_execution(rig, "aa06")
  assert query(rig, "aa06") == Ok(protocol.Executed(value))
  assert fixtures.aborts(rig.probe) == []
  stop(rig)
}

pub fn a_killed_worker_stops_the_program_as_an_abort_does_test() {
  let rig = rig(fixtures.Held)
  let _attached = attach(rig, token(1))
  let worker =
    process.spawn_unlinked(fn() {
      let _reply = start_execution(rig, "aa07", token(1))
      process.sleep_forever()
    })
  assert running(rig, "aa07")
  process.kill(worker)

  assert fixtures.eventually(fn() { query(rig, "aa07") == Ok(protocol.Unknown) })
  assert fixtures.eventually(fn() {
    fixtures.aborts(rig.probe) == [#(key("aa07").op, step("aa07"))]
  })
  stop(rig)
}

pub fn an_executor_restart_loses_the_program_and_never_replays_it_test() {
  let rig = rig(fixtures.Held)
  let _attached = attach(rig, token(1))
  let _waiting = start_execution(rig, "aa08", token(1))
  assert running(rig, "aa08")
  stop(rig)
  process.sleep(50)

  let probe = fixtures.probe(fixtures.Open)
  let restarted =
    start(rig.path, probe, fixtures.host_config(rig.path, factory(probe)))
  assert query(restarted, "aa08") == Ok(protocol.Unknown)

  // The worker's re-send before any new attach is answered from the row.
  assert heard(start_execution(restarted, "aa08", token(1)))
    == protocol.ExecutionLost
  let _attached = attach(restarted, token(2))
  assert heard(start_execution(restarted, "aa08", token(2)))
    == protocol.ExecutionLost
  assert fixtures.run_count(probe, step("aa08")) == 0
  stop(restarted)
}

pub fn an_oversized_value_is_replaced_by_an_errored_value_that_fits_test() {
  let probe = fixtures.probe(fixtures.Open)
  let path = fixtures.scratch("host-execution") <> "/ledger.db"
  let config =
    host.Config(
      ..fixtures.host_config(path, factory(probe)),
      execution_result_bytes: 600,
    )
  let rig = start(path, probe, config)
  let _attached = attach(rig, token(1))
  let big =
    owner_services.ExecutionTerms(..fixtures.execution_terms(), source: "big")

  let assert protocol.ExecutionFinished(json.Object(fields)) =
    heard(start_program(rig, "aa09", token(1), big))
    as "an oversized value is answered as an errored one"
  let assert Ok(json.String("errored")) = list_find(fields, "status")
    as "the replacement is an errored value"
  let assert Ok(json.String(message)) = list_find(fields, "message")
    as "the replacement says why"
  assert string.contains(message, "reserved 600")
  stop(rig)
}

pub fn an_execution_reserves_less_than_a_tool_call_test() {
  assert host.default_execution_result_bytes == 1_048_576
  assert host.default_execution_result_bytes < host.default_max_result_bytes
}

pub fn a_tool_call_key_never_reads_as_an_execution_value_test() {
  let rig = rig(fixtures.Open)
  let _attached = attach(rig, token(1))
  let value = fixtures.expected_value(step("aa10"), 30_000)
  assert heard(start_execution(rig, "aa10", token(1)))
    == protocol.ExecutionFinished(value)

  // A `Run` that names an execution's key gets a fault, never the program's
  // value as a tool outcome.
  let reply = process.new_subject()
  let run = fixtures.tool_run("call_1", 0)
  address.deliver(
    rig.address,
    protocol.Run(
      key: key("aa10"),
      incarnation: 0,
      token: token(1),
      run:,
      authority: fixtures.authority(),
      reply:,
    ),
  )
  let assert Ok(protocol.RunRefused(protocol.ExecutorFault(..))) =
    process.receive(reply, 5000)
    as "the stored value is not a tool outcome"
  stop(rig)
}

fn list_find(
  fields: List(#(String, json.JsonValue)),
  name: String,
) -> Result(json.JsonValue, Nil) {
  case fields {
    [] -> Error(Nil)
    [#(found, value), ..] if found == name -> Ok(value)
    [_, ..rest] -> list_find(rest, name)
  }
}
