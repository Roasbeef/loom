//// The orchestrator's surface over a real host and owner port in one VM.
////
//// These tests prove the surface's contract with the ledger: what `run` and
//// `recover` say for every row the ledger can hold, that a stale runtime is
//// fenced by the attach token, and that an executor-side callback settles
//// when the owner port dies. The two-node tests, which lose a real
//// connection, are in `remote_nodes_test`.

import client/escalate
import client/owner_services
import client/remote/address
import client/remote/host
import client/remote/owner_port
import client/remote/protocol
import client/remote/surface
import core/clock
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import machine/operation
import runtime/effects.{type ToolRun}
import support/remote_fixtures as fixtures

type Rig {
  Rig(
    host_pid: process.Pid,
    address: address.Address(protocol.HostMessage(String)),
    probe: fixtures.Probe,
    port: owner_port.Port,
    path: String,
  )
}

fn rig(gate: fixtures.Gate, asks: fixtures.Asks) -> Rig {
  let probe = fixtures.probe(gate)
  let path = fixtures.scratch("surface") <> "/ledger.db"
  let factory = fixtures.factory(probe, asks, protocol.AllRetired)
  let config = fixtures.host_config(path, factory)
  let assert Ok(started) = host.start(config) as "the host starts"
  let assert Ok(port) =
    owner_port.start(owner_port.Config(
      services: fixtures.quiet_services(),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
    ))
    as "the port starts"
  Rig(host_pid: started.pid, address: started.data, probe:, port:, path:)
}

fn stop(rig: Rig) -> Nil {
  process.unlink(rig.host_pid)
  process.kill(rig.host_pid)
}

fn config(rig: Rig, token_n: Int) -> surface.Config(String) {
  surface.Config(
    address: rig.address,
    session: "s1",
    workspace: "/work",
    incarnation: 0,
    port: rig.port,
    read_authority: fn(_run) { Ok(fixtures.authority()) },
    reconnect: fn() { Ok(Nil) },
    remote_tools: ["bash"],
    attach_within_ms: 2000,
    mint_token: fn() {
      bit_array.from_string("token-" <> int.to_string(token_n))
    },
    mcp: protocol.McpPlan(served: [], expected: []),
  )
}

fn replayable(run: ToolRun) -> ToolRun {
  effects.ToolRun(..run, replay: operation.ReplaySafe)
}

fn attached(rig: Rig, token_n: Int) -> surface.Surface(String) {
  let assert Ok(surface.Attachment(surface:, ..)) =
    surface.attach(config(rig, token_n))
    as "the attach succeeds"
  surface
}

// Runs a call from a process of its own and reports its outcome, so the test
// can kill that process the way an abort does.
fn run_in_background(
  remote: surface.Surface(String),
  run: ToolRun,
) -> #(process.Pid, process.Subject(effects.ToolOutcome)) {
  let outcome = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.send(outcome, surface.run(remote, run))
    })
  #(pid, outcome)
}

pub fn the_default_token_is_thirty_two_strong_bytes_test() {
  let first = surface.strong_token()
  assert bit_array.byte_size(first) == 32
  assert first != surface.strong_token()
}

pub fn attach_reports_the_census_and_a_run_comes_back_complete_test() {
  let rig = rig(fixtures.Open, fixtures.AsksNothing)
  let assert Ok(surface.Attachment(surface: remote, attached:)) =
    surface.attach(config(rig, 1))
  assert attached
    == protocol.Attached(
      census: "census-0",
      executor_now_ms: 1000,
      unacked: protocol.Unacked(terminal: [], unknown: [], executions: []),
    )
  let run = fixtures.tool_run("call_1", 0)

  assert surface.run(remote, run) == fixtures.expected_outcome(run)
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn a_tool_that_does_not_run_remotely_is_refused_unsent_test() {
  let rig = rig(fixtures.Open, fixtures.AsksNothing)
  let remote = attached(rig, 1)
  let local =
    effects.ToolRun(
      ..fixtures.tool_run("call_1", 0),
      call: fixtures.local_call("call_1"),
    )

  let assert effects.ToolFailed(reason:) = surface.run(remote, local)
  assert string.contains(reason, "does not run on this session's executor")
  assert !surface.places(remote, "agent_spawn")
  assert surface.places(remote, "bash")
  assert fixtures.run_count(rig.probe, "call_1") == 0
  stop(rig)
}

pub fn an_unreadable_authority_refuses_the_call_unsent_test() {
  let rig = rig(fixtures.Open, fixtures.AsksNothing)
  let blind =
    surface.Config(..config(rig, 1), read_authority: fn(_run) {
      Error("the permissions record is damaged")
    })
  let assert Ok(surface.Attachment(surface: remote, ..)) = surface.attach(blind)

  assert surface.run(remote, fixtures.tool_run("call_1", 0))
    == effects.ToolFailed(reason: "the permissions record is damaged")
  assert fixtures.run_count(rig.probe, "call_1") == 0
  stop(rig)
}

pub fn an_older_runtime_is_fenced_by_the_newer_attach_test() {
  let rig = rig(fixtures.Open, fixtures.AsksNothing)
  let dead = attached(rig, 1)
  let live = attached(rig, 2)
  let run = fixtures.tool_run("call_1", 0)

  // The dead runtime's effect, delivered after the new attach, is refused by
  // content and reaches the model as an ordinary failure.
  let assert effects.ToolFailed(reason:) = surface.run(dead, run)
  assert string.contains(reason, "newer attachment")
  assert fixtures.run_count(rig.probe, "call_1") == 0
  assert surface.run(live, run) == fixtures.expected_outcome(run)
  stop(rig)
}

pub fn recovery_reads_the_ledger_for_every_row_it_can_hold_test() {
  let rig = rig(fixtures.Open, fixtures.AsksNothing)
  let remote = attached(rig, 1)
  let run = fixtures.tool_run("call_1", 0)

  // After an attach, no row means the call never reached the executor. A call
  // that is safe to replay is only looked up, so its key stays free.
  let safe = replayable(fixtures.tool_run("call_2", 1))
  assert surface.recover(remote, safe) == effects.NotStarted
  assert surface.run(remote, safe) == fixtures.expected_outcome(safe)

  // A finished call is staged from the stored outcome, and nothing reruns.
  let _outcome = surface.run(remote, run)
  assert surface.recover(remote, run)
    == effects.Recovered(fixtures.expected_outcome(run))
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn recovery_waits_for_a_call_that_is_still_running_test() {
  let rig = rig(fixtures.Held, fixtures.AsksNothing)
  let old = attached(rig, 1)
  let run = fixtures.tool_run("call_1", 0)
  let _caller = run_in_background(old, run)
  assert fixtures.eventually(fn() {
    fixtures.run_count(rig.probe, "call_1") == 1
  })

  // The runtime restarted: a new attach, then recovery of the orphaned call.
  let fresh = attached(rig, 2)
  let recovered = process.new_subject()
  let _recoverer =
    process.spawn_unlinked(fn() {
      process.send(recovered, surface.recover(fresh, run))
    })
  assert process.receive(recovered, 100) == Error(Nil)
  fixtures.release(rig.probe)
  assert process.receive(recovered, 2000)
    == Ok(effects.Recovered(fixtures.expected_outcome(run)))
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn an_aborted_call_recovers_as_unknown_test() {
  let rig = rig(fixtures.Held, fixtures.AsksNothing)
  let remote = attached(rig, 1)
  let run = fixtures.tool_run("call_1", 0)
  let #(caller, _outcome) = run_in_background(remote, run)
  assert fixtures.eventually(fn() {
    fixtures.run_count(rig.probe, "call_1") == 1
  })
  process.kill(caller)

  // The host cancelled the run when its caller died; the row says so.
  let fresh = attached(rig, 2)
  assert fixtures.eventually(fn() {
    surface.recover(fresh, run) == effects.OutcomeUnknown
  })
  stop(rig)
}

pub fn a_restarted_executor_recovers_the_call_as_unknown_test() {
  let rig = rig(fixtures.Held, fixtures.AsksNothing)
  let remote = attached(rig, 1)
  let run = fixtures.tool_run("call_1", 0)
  let _caller = run_in_background(remote, run)
  assert fixtures.eventually(fn() {
    fixtures.run_count(rig.probe, "call_1") == 1
  })
  stop(rig)
  process.sleep(50)

  // A new host over the same ledger, reached at its own address.
  let probe = fixtures.probe(fixtures.Open)
  let factory =
    fixtures.factory(probe, fixtures.AsksNothing, protocol.AllRetired)
  let assert Ok(restarted) = host.start(fixtures.host_config(rig.path, factory))
    as "the restarted host starts"
  let next =
    Rig(..rig, host_pid: restarted.pid, address: restarted.data, probe:)
  let fresh = attached(next, 2)

  assert surface.recover(fresh, run) == effects.OutcomeUnknown
  assert fixtures.run_count(probe, "call_1") == 0
  stop(next)
}

pub fn the_owner_port_dying_settles_a_parked_escalation_promptly_test() {
  let rig = rig(fixtures.Open, fixtures.AsksOwner)

  // An owner that never decides: its escalation parks until released.
  let gate = fixtures.probe(fixtures.Held)
  let assert Ok(parked_port) =
    owner_port.start(owner_port.Config(
      services: owner_services.OwnerServices(
        ..fixtures.quiet_services(),
        escalate: fn(_refused) {
          process.call(gate.subject, 60_000, fixtures.Wait)
          escalate.Settle
        },
      ),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
    ))
    as "the parked port starts"
  let remote = attached(Rig(..rig, port: parked_port), 1)
  let run = fixtures.tool_run("call_1", 0)
  let outcome = process.new_subject()
  let _caller =
    process.spawn_unlinked(fn() {
      process.send(outcome, surface.run(remote, run))
    })

  // The tool is waiting on its owner's decision, which could take the length of
  // its remaining budget.
  assert process.receive(outcome, 200) == Error(Nil)
  let assert Ok(port_pid) = process.subject_owner(owner_port.inbox(parked_port))
  process.unlink(port_pid)
  process.kill(port_pid)

  // The executor's callback sees the port die through its monitor and settles
  // the refusal in band, so the call reaches a terminal outcome at once.
  let assert Ok(effects.ToolCompleted(result:, ..)) =
    process.receive(outcome, 2000)
  assert result == fixtures.text_result(run, "settled")
  stop(rig)
}

pub fn the_survivors_of_a_replaced_port_serve_the_new_one_test() {
  let rig = rig(fixtures.Open, fixtures.AsksOwner)
  let _first = attached(rig, 1)

  // A second attach to the open scope keeps the plane and re-points its link,
  // so the plane built for the first runtime reaches the second one's port.
  let seen = process.new_subject()
  let assert Ok(second_port) =
    owner_port.start(owner_port.Config(
      services: owner_services.OwnerServices(
        ..fixtures.quiet_services(),
        escalate: fn(_refused: escalate.Refused) {
          process.send(seen, "second port decided")
          escalate.Settle
        },
      ),
      clock: clock.fixed(at: 1000),
      settled: fn(_key) { False },
      reconcile_every_ms: 60_000,
      executions: owner_port.no_executions(),
    ))
    as "the second port starts"
  let second = attached(Rig(..rig, port: second_port), 2)

  let run = fixtures.tool_run("call_1", 0)
  assert surface.run(second, run)
    == effects.ToolCompleted(
      result: fixtures.text_result(run, "settled"),
      terminate: False,
    )
  assert process.receive(seen, 1000) == Ok("second port decided")
  assert list.length(fixtures.builds(rig.probe)) == 1
  stop(rig)
}

pub fn recovery_fences_a_call_that_must_not_run_twice_test() {
  let rig = rig(fixtures.Open, fixtures.AsksNothing)
  let remote = attached(rig, 1)
  let run = fixtures.tool_run("call_1", 0)

  // Recovery finds no row and stores "did not start" for the key.
  assert surface.recover(remote, run) == effects.NotStarted

  // The dead runtime's effect process sent its `Run` before it was killed, and
  // it reaches the host after the fence with the same token, because a restart
  // inside one open keeps the token. It must not start the call.
  assert surface.run(remote, run)
    == effects.ToolFailed(reason: protocol.did_not_run_text)
  assert fixtures.run_count(rig.probe, "call_1") == 0

  // Asking again reads the stored row and says the same thing.
  assert surface.recover(remote, run)
    == effects.Recovered(effects.ToolFailed(reason: protocol.did_not_run_text))
  stop(rig)
}

pub fn recovery_waits_for_a_stale_run_that_beat_the_fence_test() {
  let rig = rig(fixtures.Held, fixtures.AsksNothing)
  let remote = attached(rig, 1)
  let run = fixtures.tool_run("call_1", 0)

  // The stale `Run` is admitted first, from the same attach.
  let _stale = run_in_background(remote, run)
  assert fixtures.eventually(fn() {
    fixtures.run_count(rig.probe, "call_1") == 1
  })

  // Recovery's fence finds it live, waits, and returns the real outcome.
  let recovered = process.new_subject()
  let _recoverer =
    process.spawn_unlinked(fn() {
      process.send(recovered, surface.recover(remote, run))
    })
  assert process.receive(recovered, 100) == Error(Nil)
  fixtures.release(rig.probe)
  assert process.receive(recovered, 2000)
    == Ok(effects.Recovered(fixtures.expected_outcome(run)))
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn a_replayable_call_is_not_fenced_so_the_replay_runs_test() {
  let rig = rig(fixtures.Open, fixtures.AsksNothing)
  let remote = attached(rig, 1)
  let run = replayable(fixtures.tool_run("call_1", 0))

  // Recovery says not started and writes nothing. The planner then replays the
  // call under the same key, and it runs.
  assert surface.recover(remote, run) == effects.NotStarted
  assert surface.run(remote, run) == fixtures.expected_outcome(run)
  assert fixtures.run_count(rig.probe, "call_1") == 1
  stop(rig)
}

pub fn an_attach_that_meets_a_build_in_progress_waits_for_it_test() {
  // An attach whose reply the link lost has started the build, and the
  // orchestrator's repair sends the same attach again. The host refuses the
  // second one while the first is building, and the open must not fail on that
  // refusal: the build is seconds long and the refusal asks for another try.
  let rig = rig(fixtures.Open, fixtures.AsksNothing)
  fixtures.hold_build(rig.probe, "s1")
  address.deliver(
    rig.address,
    protocol.Attach(
      version: protocol.version,
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      token: bit_array.from_string("token-lost"),
      owner_port: owner_port.inbox(rig.port),
      reply: process.new_subject(),
      mcp: protocol.McpPlan(served: [], expected: []),
    ),
  )
  assert fixtures.eventually(fn() {
    list.length(fixtures.builds(rig.probe)) == 1
  })

  let attaching = process.new_subject()
  let _attacher =
    process.spawn_unlinked(fn() {
      process.send(attaching, surface.attach(config(rig, 2)))
    })

  // The attach has been refused at least once and is still asking.
  assert process.receive(attaching, 300) == Error(Nil)
  fixtures.release_build(rig.probe, "s1")
  let assert Ok(Ok(surface.Attachment(surface: remote, ..))) =
    process.receive(attaching, 3000)
    as "the attach succeeds once the build lands"
  let run = fixtures.tool_run("call_1", 0)
  assert surface.run(remote, run) == fixtures.expected_outcome(run)
  assert list.length(fixtures.builds(rig.probe)) == 1
  stop(rig)
}

pub fn an_attach_that_never_sees_the_build_finish_reports_it_building_test() {
  let rig = rig(fixtures.Open, fixtures.AsksNothing)
  fixtures.hold_build(rig.probe, "s1")
  address.deliver(
    rig.address,
    protocol.Attach(
      version: protocol.version,
      session: "s1",
      workspace: "/work",
      incarnation: 0,
      token: bit_array.from_string("token-lost"),
      owner_port: owner_port.inbox(rig.port),
      reply: process.new_subject(),
      mcp: protocol.McpPlan(served: [], expected: []),
    ),
  )
  assert fixtures.eventually(fn() {
    list.length(fixtures.builds(rig.probe)) == 1
  })

  let impatient = surface.Config(..config(rig, 2), attach_within_ms: 200)

  assert surface.attach(impatient) == Error(protocol.PlaneBuilding)
  fixtures.release_build(rig.probe, "s1")
  stop(rig)
}
