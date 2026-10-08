//// The executor's host against a real ledger and a fake workspace plane.
////
//// The host is driven directly with the protocol's own messages, so each test
//// names the rule it proves: a call runs once, an outcome is committed before
//// it is told, a request from a dead runtime is refused by content, and an
//// abort stops the call while a lost connection does not. The fake tool counts
//// its runs, and that count is the number every test of idempotence reads.

import client/remote/address.{type Address}
import client/remote/host
import client/remote/protocol.{
  type HostMessage, type Key, type Refusal, type RunAnswer,
}
import gleam/bit_array
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import runtime/effects.{type ToolRun}
import support/remote_fixtures as fixtures
import tools/fs

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

fn key_of(run: ToolRun) -> Key {
  protocol.key_of("s1", run)
}

// A host over a new ledger.
fn rig(gate: fixtures.Gate) -> Rig {
  let probe = fixtures.probe(gate)
  let path = fixtures.scratch("host") <> "/ledger.db"
  start_at(
    path,
    probe,
    fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired),
  )
}

fn start_at(
  path: String,
  probe: fixtures.Probe,
  factory: host.PlaneFactory(String),
) -> Rig {
  start_config(path, probe, fixtures.host_config(path, factory))
}

fn start_config(
  path: String,
  probe: fixtures.Probe,
  config: host.Config(String),
) -> Rig {
  let assert Ok(started) = host.start(config) as "the host starts"
  Rig(address: started.data, pid: started.pid, probe:, path:)
}

// Ends a host without taking the test process with it.
fn stop(rig: Rig) -> Nil {
  process.unlink(rig.pid)
  process.kill(rig.pid)
}

fn attach(
  rig: Rig,
  incarnation: Int,
  attach_token: BitArray,
) -> Result(protocol.Attached(String), Refusal) {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Attach(
      version: protocol.version,
      session: "s1",
      workspace: "/work",
      incarnation:,
      token: attach_token,
      owner_port: process.new_subject(),
      reply:,
    ),
  )
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers an attach"
  answer
}

fn send_run(
  rig: Rig,
  run: ToolRun,
  incarnation: Int,
  attach_token: BitArray,
) -> Subject(RunAnswer) {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Run(
      key: key_of(run),
      incarnation:,
      token: attach_token,
      run:,
      authority: fixtures.authority(),
      reply:,
    ),
  )
  reply
}

fn heard(reply: Subject(RunAnswer)) -> RunAnswer {
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers a run"
  answer
}

fn query(rig: Rig, run: ToolRun) -> Result(protocol.Lookup, Refusal) {
  let reply = process.new_subject()
  address.deliver(rig.address, protocol.Query(key_of(run), reply))
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers a query"
  answer
}

fn query_or_fence(
  rig: Rig,
  run: ToolRun,
  incarnation: Int,
) -> Result(protocol.Lookup, Refusal) {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.QueryOrFence(key_of(run), incarnation, reply),
  )
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers a fence query"
  answer
}

fn close(rig: Rig, incarnation: Int) -> Result(protocol.CloseOutcome, Refusal) {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Close(session: "s1", workspace: "/work", incarnation:, reply:),
  )
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers a close"
  answer
}

fn running(rig: Rig, call: String) -> Bool {
  fixtures.eventually(fn() { fixtures.run_count(rig.probe, call) == 1 })
}

pub fn a_fresh_run_commits_its_outcome_and_replies_test() {
  let rig = rig(fixtures.Open)
  let assert Ok(protocol.Attached(census: "census-0", ..)) =
    attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)

  // The outcome is in the ledger by the time the reply is.
  assert heard(send_run(rig, run, 0, token(1)))
    == protocol.RunFinished(fixtures.expected_outcome(run))
  assert query(rig, run)
    == Ok(protocol.Terminal(fixtures.expected_outcome(run)))
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn a_duplicate_run_while_live_joins_it_and_the_tool_runs_once_test() {
  let rig = rig(fixtures.Held)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)
  let first = send_run(rig, run, 0, token(1))
  assert running(rig, "call_1")
  assert query(rig, run) == Ok(protocol.Admitted)

  // The second request is the orchestrator's re-send after a reconnect. It
  // becomes a waiter on the live run and starts nothing.
  let second = send_run(rig, run, 0, token(1))
  fixtures.release(rig.probe)
  assert heard(first) == protocol.RunFinished(fixtures.expected_outcome(run))
  assert heard(second) == protocol.RunFinished(fixtures.expected_outcome(run))
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn a_duplicate_run_after_the_outcome_returns_the_stored_one_test() {
  let rig = rig(fixtures.Open)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)
  let first = heard(send_run(rig, run, 0, token(1)))

  assert heard(send_run(rig, run, 0, token(1))) == first
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn a_stale_token_is_refused_after_a_second_attach_test() {
  let rig = rig(fixtures.Open)
  let assert Ok(_first) = attach(rig, 0, token(1))
  let assert Ok(_second) = attach(rig, 0, token(2))
  let run = fixtures.tool_run("call_1", 0)

  // The dead runtime's run is refused by content, and nothing ran.
  assert heard(send_run(rig, run, 0, token(1)))
    == protocol.RunRefused(protocol.StaleToken)
  assert fixtures.run_count(rig.probe, "call_1") == 0
  assert query(rig, run) == Ok(protocol.Missing)

  // The plane built for the first attach is kept for the second.
  assert list.length(fixtures.builds(rig.probe)) == 1
  assert heard(send_run(rig, run, 0, token(2)))
    == protocol.RunFinished(fixtures.expected_outcome(run))
  stop(rig)
}

pub fn a_stale_incarnation_is_refused_test() {
  let rig = rig(fixtures.Open)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)

  assert heard(send_run(rig, run, 1, token(1)))
    == protocol.RunRefused(protocol.StaleIncarnation(0))
  assert fixtures.run_count(rig.probe, "call_1") == 0
  stop(rig)
}

pub fn a_run_before_any_attach_is_refused_test() {
  let rig = rig(fixtures.Open)
  let run = fixtures.tool_run("call_1", 0)

  let assert protocol.RunRefused(protocol.NoPlane(..)) =
    heard(send_run(rig, run, 0, token(1)))
  assert query(rig, run) == Ok(protocol.Missing)
  stop(rig)
}

pub fn a_failed_plane_build_leaves_the_scope_open_for_a_retry_test() {
  let probe = fixtures.probe(fixtures.Open)
  let good = fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired)
  let failing_once = fn(spec: host.AttachSpec) {
    case list.length(fixtures.builds(probe)) {
      0 -> {
        process.send(probe.subject, fixtures.Built(owner: spec.owner))
        Error("no space for the workspace")
      }
      _ -> good(spec)
    }
  }
  let rig =
    start_at(fixtures.scratch("host") <> "/ledger.db", probe, failing_once)

  assert attach(rig, 0, token(1))
    == Error(protocol.NoPlane("no space for the workspace"))
  let run = fixtures.tool_run("call_1", 0)
  let assert protocol.RunRefused(protocol.NoPlane(..)) =
    heard(send_run(rig, run, 0, token(1)))

  // The retry is a rebind at the same incarnation, and builds the plane.
  let assert Ok(protocol.Attached(census: "census-0", ..)) =
    attach(rig, 0, token(2))
  assert heard(send_run(rig, run, 0, token(2)))
    == protocol.RunFinished(fixtures.expected_outcome(run))
  stop(rig)
}

pub fn an_abort_cancels_the_run_and_marks_it_unknown_test() {
  let rig = rig(fixtures.Held)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)

  // The orchestrator's effect process sends the run and waits; abort is its
  // death with reason `kill`.
  let caller =
    process.spawn_unlinked(fn() {
      let _reply = send_run(rig, run, 0, token(1))
      process.sleep_forever()
    })
  assert running(rig, "call_1")
  let assert [#(tool, _call)] = fixtures.runs(rig.probe)
  process.kill(caller)

  assert fixtures.eventually(fn() { query(rig, run) == Ok(protocol.Unknown) })
  assert fixtures.eventually(fn() { !process.is_alive(tool) })

  // A later request for the key never starts it again.
  assert heard(send_run(rig, run, 0, token(1))) == protocol.RunLost
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn a_call_with_another_waiter_survives_one_waiter_dying_test() {
  let rig = rig(fixtures.Held)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)
  let doomed =
    process.spawn_unlinked(fn() {
      let _reply = send_run(rig, run, 0, token(1))
      process.sleep_forever()
    })
  assert running(rig, "call_1")
  let survivor = send_run(rig, run, 0, token(1))
  process.kill(doomed)

  // One abort does not stop a call another process still waits for.
  process.sleep(50)
  assert query(rig, run) == Ok(protocol.Admitted)
  fixtures.release(rig.probe)
  assert heard(survivor) == protocol.RunFinished(fixtures.expected_outcome(run))
  stop(rig)
}

pub fn only_noconnection_leaves_a_call_running_test() {
  let noconnection = atom.to_dynamic(atom.create("noconnection"))
  assert !host.cancels_run(process.Abnormal(noconnection))

  // Every other way a caller can end is an abort, including a clean exit
  // before the answer and a crash.
  assert host.cancels_run(process.Killed)
  assert host.cancels_run(process.Normal)
  assert host.cancels_run(
    process.Abnormal(atom.to_dynamic(atom.create("noproc"))),
  )
}

pub fn closing_with_a_live_run_marks_it_unknown_and_reports_the_plane_test() {
  let rig = rig(fixtures.Held)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)
  let waiting = send_run(rig, run, 0, token(1))
  assert running(rig, "call_1")
  let assert [#(tool, _call)] = fixtures.runs(rig.probe)

  assert close(rig, 0) == Ok(protocol.AllRetired)
  assert heard(waiting) == protocol.RunLost
  assert query(rig, run) == Ok(protocol.Unknown)
  assert fixtures.eventually(fn() { !process.is_alive(tool) })
  assert fixtures.closes(rig.probe) == 1

  // A closed scope admits nothing.
  let other = fixtures.tool_run("call_2", 1)
  let assert protocol.RunRefused(_) = heard(send_run(rig, other, 0, token(1)))
  stop(rig)
}

pub fn reopening_after_a_clean_close_builds_a_new_plane_test() {
  let rig = rig(fixtures.Open)
  let assert Ok(protocol.Attached(census: "census-0", ..)) =
    attach(rig, 0, token(1))
  assert close(rig, 0) == Ok(protocol.AllRetired)

  // The old incarnation can never attach again; the next one reopens the scope
  // and gets a plane of its own.
  assert attach(rig, 0, token(2)) == Error(protocol.StaleIncarnation(0))
  let assert Ok(protocol.Attached(census: "census-1", ..)) =
    attach(rig, 1, token(3))
  assert list.length(fixtures.builds(rig.probe)) == 2
  let run = fixtures.tool_run("call_1", 0)
  assert heard(send_run(rig, run, 1, token(3)))
    == protocol.RunFinished(fixtures.expected_outcome(run))
  stop(rig)
}

pub fn an_unclean_close_gets_no_successor_test() {
  let probe = fixtures.probe(fixtures.Open)
  let rig =
    start_at(
      fixtures.scratch("host") <> "/ledger.db",
      probe,
      fixtures.factory(probe, fixtures.AsksNothing, protocol.UnknownCleanup(2)),
    )
  let assert Ok(_attached) = attach(rig, 0, token(1))

  // The plane could not prove two children gone, so the scope stays unclean.
  assert close(rig, 0) == Ok(protocol.UnknownCleanup(2))
  assert attach(rig, 1, token(2)) == Error(protocol.UncleanClose(2))
  stop(rig)
}

pub fn a_host_restart_turns_a_live_call_into_unknown_test() {
  let rig = rig(fixtures.Held)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)
  let _waiting = send_run(rig, run, 0, token(1))
  assert running(rig, "call_1")
  stop(rig)
  process.sleep(50)

  // A new host over the same ledger is a new VM as far as the ledger knows.
  let probe = fixtures.probe(fixtures.Open)
  let restarted =
    start_at(
      rig.path,
      probe,
      fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired),
    )
  assert query(restarted, run) == Ok(protocol.Unknown)

  // The attach is a rebind that rebuilds the plane, and lists the lost call.
  let assert Ok(protocol.Attached(unacked:, ..)) =
    attach(restarted, 0, token(2))
  assert unacked == protocol.Unacked(terminal: [], unknown: [key_of(run)])
  assert heard(send_run(restarted, run, 0, token(2))) == protocol.RunLost
  assert fixtures.run_count(probe, "call_1") == 0
  stop(restarted)
}

pub fn an_oversized_outcome_is_replaced_by_a_failure_that_fits_test() {
  let probe = fixtures.probe(fixtures.Open)
  let path = fixtures.scratch("host") <> "/ledger.db"
  let config =
    host.Config(
      ..fixtures.host_config(
        path,
        fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired),
      ),
      max_result_bytes: 150,
    )
  let rig = start_config(path, probe, config)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)

  let assert protocol.RunFinished(effects.ToolFailed(reason:)) =
    heard(send_run(rig, run, 0, token(1)))
  assert reason != ""
  assert query(rig, run) == Ok(protocol.Terminal(effects.ToolFailed(reason:)))
  stop(rig)
}

pub fn an_ack_deletes_the_row_and_a_listing_reports_what_waits_test() {
  let rig = rig(fixtures.Open)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)
  let _answer = heard(send_run(rig, run, 0, token(1)))

  let listed = fn() {
    let reply = process.new_subject()
    address.deliver(rig.address, protocol.ListUnacked("s1", reply))
    let assert Ok(answer) = process.receive(reply, 5000)
      as "the host answers a listing"
    answer
  }
  assert listed() == Ok(protocol.Unacked(terminal: [key_of(run)], unknown: []))

  // The acknowledgement is a cast, so the row goes when the host gets to it.
  address.deliver(rig.address, protocol.Ack(key_of(run)))
  assert fixtures.eventually(fn() { query(rig, run) == Ok(protocol.Missing) })
  assert listed() == Ok(protocol.Unacked(terminal: [], unknown: []))
  stop(rig)
}

pub fn a_fence_before_a_stale_run_stops_the_run_from_starting_test() {
  let rig = rig(fixtures.Open)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)

  // Recovery asked first and found no row, so it stored "did not start".
  assert query_or_fence(rig, run, 0) == Ok(protocol.Fenced)
  let did_not_run = effects.ToolFailed(reason: protocol.did_not_run_text)
  assert query(rig, run) == Ok(protocol.Terminal(did_not_run))

  // The dead runtime's `Run` arrives with the current token. The key is taken,
  // so it is told what the fence stored and the tool never starts.
  assert heard(send_run(rig, run, 0, token(1)))
    == protocol.RunFinished(did_not_run)
  assert fixtures.run_count(rig.probe, "call_1") == 0
  assert fixtures.runs(rig.probe) == []
  stop(rig)
}

pub fn a_fence_after_a_stale_run_finds_it_live_and_waits_for_it_test() {
  let rig = rig(fixtures.Held)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)
  let stale = send_run(rig, run, 0, token(1))
  assert running(rig, "call_1")

  // Recovery arrives second: the call is live, and nothing is written.
  assert query_or_fence(rig, run, 0) == Ok(protocol.Admitted)
  fixtures.release(rig.probe)
  assert heard(stale) == protocol.RunFinished(fixtures.expected_outcome(run))
  assert query_or_fence(rig, run, 0)
    == Ok(protocol.Terminal(fixtures.expected_outcome(run)))
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn a_second_fence_reports_the_stored_did_not_run_test() {
  let rig = rig(fixtures.Open)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  let run = fixtures.tool_run("call_1", 0)
  assert query_or_fence(rig, run, 0) == Ok(protocol.Fenced)

  // Recovery that repeats after another restart reads the row the first one
  // wrote, so the answer does not change and no second row appears.
  assert query_or_fence(rig, run, 0)
    == Ok(
      protocol.Terminal(effects.ToolFailed(reason: protocol.did_not_run_text)),
    )
  stop(rig)
}

pub fn a_fence_from_the_wrong_incarnation_or_no_scope_is_refused_test() {
  let rig = rig(fixtures.Open)
  let run = fixtures.tool_run("call_1", 0)
  assert query_or_fence(rig, run, 0) == Error(protocol.NoSuchScope)
  let assert Ok(_attached) = attach(rig, 0, token(1))
  assert query_or_fence(rig, run, 1) == Error(protocol.StaleIncarnation(0))

  // Nothing was written, so the key is still free for a real run.
  assert query(rig, run) == Ok(protocol.Missing)
  stop(rig)
}

pub fn an_attach_from_another_protocol_version_is_refused_test() {
  let rig = rig(fixtures.Open)
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Attach(
      version: protocol.version + 1,
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      token: token(1),
      owner_port: process.new_subject(),
      reply:,
    ),
  )
  let assert Ok(answer) = process.receive(reply, 5000)
    as "the host answers a skewed attach"
  assert answer == Error(protocol.VersionMismatch(supported: protocol.version))

  // Nothing was built or bound, so a correct attach still creates the scope.
  assert fixtures.builds(rig.probe) == []
  let assert Ok(_attached) = attach(rig, 0, token(1))
  stop(rig)
}

pub fn the_result_reservation_covers_the_largest_file_read_test() {
  // A maximum-size image inflates by a third under base64, and the result is
  // wrapped in JSON on top, so twice the read limit is the reservation.
  assert host.default_max_result_bytes >= 2 * fs.max_read_bytes
}

fn attach_as(
  rig: Rig,
  session: String,
  attach_token: BitArray,
) -> Subject(Result(protocol.Attached(String), Refusal)) {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Attach(
      version: protocol.version,
      session:,
      workspace: "/work",
      incarnation: 0,
      token: attach_token,
      owner_port: process.new_subject(),
      reply:,
    ),
  )
  reply
}

fn run_as(rig: Rig, session: String, run: ToolRun) -> Subject(RunAnswer) {
  let reply = process.new_subject()
  address.deliver(
    rig.address,
    protocol.Run(
      key: protocol.key_of(session, run),
      incarnation: 0,
      token: token(1),
      run:,
      authority: fixtures.authority(),
      reply:,
    ),
  )
  reply
}

pub fn a_slow_build_for_one_session_does_not_delay_another_test() {
  let rig = rig(fixtures.Open)
  fixtures.hold_build(rig.probe, "slow")

  // The slow session's attach is accepted and its build is parked in the
  // factory, so the host has no answer for it yet.
  let slow = attach_as(rig, "slow", token(1))
  assert fixtures.eventually(fn() {
    list.length(fixtures.builds(rig.probe)) == 1
  })
  assert process.receive(slow, 100) == Error(Nil)

  // Another session attaches and runs a tool while that build is in flight.
  let quick = attach_as(rig, "quick", token(1))
  let assert Ok(Ok(protocol.Attached(census: "census-0", ..))) =
    process.receive(quick, 2000)
  let run = fixtures.tool_run("call_1", 0)
  assert heard(run_as(rig, "quick", run))
    == protocol.RunFinished(fixtures.expected_outcome(run))
  assert process.receive(slow, 100) == Error(Nil)

  // The held build lands and its attach is answered.
  fixtures.release_build(rig.probe, "slow")
  let assert Ok(Ok(protocol.Attached(census: "census-0", ..))) =
    process.receive(slow, 2000)
  stop(rig)
}

pub fn a_session_that_is_building_refuses_attach_run_and_close_test() {
  let rig = rig(fixtures.Open)
  fixtures.hold_build(rig.probe, "s1")
  let first = attach_as(rig, "s1", token(1))
  assert fixtures.eventually(fn() {
    list.length(fixtures.builds(rig.probe)) == 1
  })

  // A second attach is refused, not queued, and it did not replace the token
  // the first attach is waiting on.
  assert process.receive(attach_as(rig, "s1", token(2)), 2000)
    == Ok(Error(protocol.PlaneBuilding))
  let run = fixtures.tool_run("call_1", 0)
  assert heard(send_run(rig, run, 0, token(1)))
    == protocol.RunRefused(protocol.PlaneBuilding)
  assert close(rig, 0) == Error(protocol.PlaneBuilding)
  assert fixtures.run_count(rig.probe, "call_1") == 0

  fixtures.release_build(rig.probe, "s1")
  let assert Ok(Ok(_attached)) = process.receive(first, 2000)
  assert heard(send_run(rig, run, 0, token(1)))
    == protocol.RunFinished(fixtures.expected_outcome(run))
  assert list.length(fixtures.builds(rig.probe)) == 1
  stop(rig)
}

pub fn a_build_that_fails_is_reported_and_retried_by_the_next_attach_test() {
  let probe = fixtures.probe(fixtures.Open)
  let path = fixtures.scratch("host") <> "/ledger.db"
  let attempts = process.new_subject()
  let rig =
    start_at(path, probe, fn(spec: host.AttachSpec) {
      process.send(attempts, spec.incarnation)
      Error("no checkout here")
    })
  assert attach(rig, 0, token(1)) == Error(protocol.NoPlane("no checkout here"))

  // The scope stayed open without a plane, so the retry builds again at the
  // same incarnation instead of finding a closed scope.
  assert attach(rig, 0, token(2)) == Error(protocol.NoPlane("no checkout here"))
  assert process.receive(attempts, 100) == Ok(0)
  assert process.receive(attempts, 100) == Ok(0)
  stop(rig)
}
