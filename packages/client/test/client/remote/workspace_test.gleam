//// The orchestrator's workspace half over a real host in one VM.
////
//// The executor is the real host and ledger with a fake plane, so these tests
//// prove what the orchestrator does with an executor's answers: which
//// incarnation it attaches at after each way a scope can have ended, what it
//// records, how it routes recovery, which clock its non-tool callers read,
//// and that one open attaches once.

import client/extension/hooks as extension_hooks
import client/jobstate
import client/remote/owner_port
import client/remote/protocol
import client/remote/scope
import client/remote/workspace
import core/clock
import core/ids
import core/json
import core/register
import core/tx
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/codec
import machine/operation
import machine/strand
import runtime/effects
import session/session
import storage/exec_ledger
import storage/storage
import support/remote_fixtures as fixtures
import support/remote_orchestrator as rig
import telemetry/log

fn store() -> session.Session {
  let assert Ok(opened) = session.open_memory(clock.fixed(at: 1000))
    as "the store opens"
  opened
}

fn attached(executor: rig.Executor, opened: session.Session) {
  let assert Ok(hands) =
    workspace.attach(rig.registered(executor, opened, clock.fixed(at: 1000)))
    as "the attach succeeds"
  hands
}

fn standard(
  probe: fixtures.Probe,
  close: protocol.CloseOutcome,
) -> rig.Executor {
  rig.start(rig.factory(probe, rig.census(rig.standard_tools()), close))
}

pub fn an_attach_records_the_open_and_builds_the_plane_from_the_census_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()

  let hands = attached(executor, opened)

  assert hands.incarnation == 1
  assert scope.read(opened)
    == Ok(Some(scope.Scope(1, None, Some(rig.executor_name))))
  assert hands.tools == rig.standard_tools()
  assert hands.plane.census.workspace == rig.executor_root
  assert hands.plane.fatal == []
  let assert Ok(facts) = hands.plane.prompt_facts()
  assert facts.guidance != []
  let run = fixtures.tool_run("call_1", 0)
  assert hands.plane.run(run, fixtures.authority())
    == effects.ToolCompleted(
      result: fixtures.text_result(run, "ran:bash"),
      terminate: False,
    )
  rig.stop(executor)
}

pub fn the_non_tool_clock_reads_the_executors_timebase_test() {
  // The executor's clock is an hour ahead of this machine's. An absolute
  // deadline a hook or a Git observation puts in a `CallSpec` is compared with
  // the executor's clock, so the clock those callers read must be the
  // executor's.
  let skew = 3_600_000
  let probe = fixtures.probe(fixtures.Open)
  let executor =
    rig.start_on(
      rig.factory(probe, rig.census(rig.standard_tools()), protocol.AllRetired),
      executor_clock: clock.fixed(at: 1000 + skew),
    )

  let hands = attached(executor, store())

  assert clock.read(hands.clock).0 == 1000 + skew
  rig.stop(executor)
}

pub fn a_rebound_attach_reads_the_executors_clock_now_test() {
  // The scope was built when the executor's clock read `built_at`. An open
  // that rebinds to it two hours later must rebase on the executor's time at
  // that attach. Rebasing on the census would leave every deadline a hook or a
  // Git observation computes two hours in the executor's past.
  let built_at = 1000 + 3_600_000
  let two_hours = 7_200_000
  let #(executor_clock, set_executor_time) = rig.settable_clock(from: built_at)
  let probe = fixtures.probe(fixtures.Open)
  let executor =
    rig.start_on(
      rig.factory(probe, rig.census(rig.standard_tools()), protocol.AllRetired),
      executor_clock:,
    )
  let opened = store()
  let first = attached(executor, opened)
  assert clock.read(first.clock).0 == built_at

  set_executor_time(built_at + two_hours)
  let second = attached(executor, opened)

  assert first.incarnation == second.incarnation
  assert list.length(fixtures.builds(probe)) == 1
  assert clock.read(second.clock).0 == built_at + two_hours
  rig.stop(executor)
}

pub fn the_rebased_clock_adds_the_measured_difference_test() {
  let rebased =
    workspace.rebased(
      clock.fixed(at: 1000),
      executor_now_ms: 15_000,
      local_now_ms: 5000,
    )
  assert clock.read(rebased).0 == 11_000
}

pub fn a_clean_close_is_recorded_and_the_next_open_attaches_one_higher_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()
  let first = attached(executor, opened)
  assert first.incarnation == 1

  first.plane.close()

  assert scope.read(opened)
    == Ok(
      Some(scope.Scope(1, Some(protocol.AllRetired), Some(rig.executor_name))),
    )
  assert fixtures.closes(probe) == 1
  let second = attached(executor, opened)
  assert second.incarnation == 2
  assert scope.read(opened)
    == Ok(Some(scope.Scope(2, None, Some(rig.executor_name))))
  rig.stop(executor)
}

pub fn an_open_that_was_never_closed_attaches_at_the_same_incarnation_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()
  let first = attached(executor, opened)

  let second = attached(executor, opened)

  assert first.incarnation == 1
  assert second.incarnation == 1
  rig.stop(executor)
}

pub fn a_close_with_unknown_cleanup_gets_no_successor_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.UnknownCleanup(2))
  let opened = store()
  let first = attached(executor, opened)

  first.plane.close()

  assert scope.read(opened)
    == Ok(
      Some(scope.Scope(
        1,
        Some(protocol.UnknownCleanup(2)),
        Some(rig.executor_name),
      )),
    )
  let assert Error(reason) =
    workspace.attach(rig.registered(executor, opened, clock.fixed(at: 1000)))
  assert string.starts_with(reason, "executor_unavailable: ")
  assert string.contains(reason, "2 children")
  rig.stop(executor)
}

pub fn a_scope_an_executor_restart_left_unproven_reopens_after_a_release_test() {
  // The executor's VM restarts while the session is open. The new VM has no
  // plane for the scope, so the session's close finds no witness and records
  // unknown cleanup, and the scope then refuses every attach. An operator's
  // release is the way out, and the next open must ask for the incarnation
  // after the one that closed.
  let path = fixtures.scratch("restart-release") <> "/ledger.db"
  let name = rig.host_name()
  let probe = fixtures.probe(fixtures.Open)
  let factory = fn() {
    rig.factory(probe, rig.census(rig.standard_tools()), protocol.AllRetired)
  }
  let first = rig.start_named(path, factory(), name)
  let opened = store()
  let hands = attached(first, opened)
  assert hands.incarnation == 1
  rig.stop(first)
  process.sleep(100)
  let second = rig.start_named(path, factory(), name)

  hands.plane.close()

  assert scope.read(opened)
    == Ok(
      Some(scope.Scope(
        1,
        Some(protocol.UnknownCleanup(0)),
        Some(rig.executor_name),
      )),
    )
  let assert Error(refused) =
    workspace.attach(rig.registered(second, opened, clock.fixed(at: 1000)))
  assert string.contains(refused, "0 children")
  assert string.contains(refused, "`loomd executor release registered-session`")

  // The executor daemon is stopped for the release.
  rig.stop(second)
  process.sleep(100)
  let assert Ok(ledger) = exec_ledger.open(path) as "the ledger opens"
  let assert Ok(exec_ledger.Released(incarnation: 1, ..)) =
    exec_ledger.release(ledger, "registered-session", 2000)
    as "the scope is released"
  let assert Ok(Nil) = exec_ledger.close(ledger) as "the ledger closes"
  let third = rig.start_named(path, factory(), name)

  let reopened = attached(third, opened)

  assert reopened.incarnation == 2
  assert scope.read(opened)
    == Ok(Some(scope.Scope(2, None, Some(rig.executor_name))))
  rig.stop(third)
}

pub fn a_close_the_record_never_saw_is_learned_from_the_executor_test() {
  // The executor's host ended after it began the close, and the orchestrator
  // never recorded that close. An operator released the scope, so the executor
  // holds it closed at incarnation 1 while the record still says the open at 1
  // was never closed. The open must learn the close from the executor and
  // reopen at incarnation 2, not fail as out of step.
  let path = fixtures.scratch("unrecorded-close") <> "/ledger.db"
  let name = rig.host_name()
  let probe = fixtures.probe(fixtures.Open)
  let factory = fn() {
    rig.factory(probe, rig.census(rig.standard_tools()), protocol.AllRetired)
  }
  let first = rig.start_named(path, factory(), name)
  let opened = store()
  let hands = attached(first, opened)
  assert hands.incarnation == 1
  rig.stop(first)
  process.sleep(100)
  let assert Ok(ledger) = exec_ledger.open(path) as "the ledger opens"
  let assert Ok(Nil) =
    exec_ledger.begin_close(ledger, "registered-session", "registered-name", 1)
    as "the close begins and never finishes"
  let assert Ok(exec_ledger.Released(was: exec_ledger.Closing, ..)) =
    exec_ledger.release(ledger, "registered-session", 2000)
    as "the scope is released"
  let assert Ok(Nil) = exec_ledger.close(ledger) as "the ledger closes"
  let second = rig.start_named(path, factory(), name)
  assert scope.read(opened)
    == Ok(Some(scope.Scope(1, None, Some(rig.executor_name))))

  let reopened = attached(second, opened)

  assert reopened.incarnation == 2
  assert scope.read(opened)
    == Ok(Some(scope.Scope(2, None, Some(rig.executor_name))))
  rig.stop(second)
}

pub fn a_record_out_of_step_with_the_executor_fails_naming_both_numbers_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()
  let first = attached(executor, opened)
  first.plane.close()

  // The record claims the scope was reopened five times; the executor's
  // ledger says it was closed at incarnation one.
  let assert Ok(Nil) =
    scope.write(opened, scope.Scope(5, None, Some(rig.executor_name)))
  let assert Error(reason) =
    workspace.attach(rig.registered(executor, opened, clock.fixed(at: 1000)))

  assert string.starts_with(reason, "executor_unavailable: ")
  assert string.contains(reason, "incarnation 5")
  assert string.contains(reason, "incarnation 1")
  rig.stop(executor)
}

pub fn an_unreachable_executor_fails_before_anything_is_recorded_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()
  let down =
    rig.registered_in(
      rig.placement_of(
        [
          rig.candidate_over(
            rig.executor_name,
            workspace.Reach(..rig.reach(executor), connect: fn() {
              Error("the handshake was refused")
            }),
          ),
        ],
        fn(_name) { Nil },
      ),
      opened,
      clock.fixed(at: 1000),
    )

  assert workspace.attach(down)
    == Error("executor_unavailable: the handshake was refused")
  assert scope.read(opened) == Ok(None)
  assert fixtures.run_count(probe, "call_1") == 0
  rig.stop(executor)
}

pub fn a_second_open_rotates_the_token_and_recovers_a_finished_call_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()
  let first = attached(executor, opened)
  let finished = fixtures.tool_run("call_1", 0)
  let outcome = first.plane.run(finished, fixtures.authority())

  // The call's result was never staged here, so the store still holds it
  // pending, which is why the executor must keep its row.
  holds_pending(opened, finished)

  // The orchestrator session restarts: a new open attaches with a new token.
  let second = attached(executor, opened)

  assert second.recover(finished) == effects.Recovered(outcome:)
  assert fixtures.run_count(probe, "call_1") == 1

  // What the earlier open still sends is refused by content.
  let late = fixtures.tool_run("call_2", 1)
  let assert effects.ToolFailed(reason:) =
    first.plane.run(late, fixtures.authority())
  assert string.contains(reason, "newer attachment")
  assert fixtures.run_count(probe, "call_2") == 0
  rig.stop(executor)
}

pub fn a_staged_result_is_acknowledged_when_the_next_open_attaches_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()
  let first = attached(executor, opened)
  let finished = fixtures.tool_run("call_1", 0)
  let _outcome = first.plane.run(finished, fixtures.authority())

  // Nothing here holds the call pending, so its row is a leak the reconciler
  // retires: the attach lists it and the port acknowledges it. The key stays
  // taken, as a tombstone, so the executor now reports it as lost and not as a
  // key that never arrived.
  let second = attached(executor, opened)

  assert fixtures.eventually(fn() {
    second.recover(finished) == effects.OutcomeUnknown
  })
  rig.stop(executor)
}

pub fn recovery_follows_the_calls_placement_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let hands = attached(executor, store())

  // A workspace call the executor never saw did not start.
  assert hands.recover(fixtures.tool_run("never_sent", 3)) == effects.NotStarted

  // An owner call never reached the executor; it is judged by its own policy,
  // as it is in a session with no recovery.
  let owner_call = fn(replay) {
    effects.ToolRun(
      ..fixtures.tool_run("owner_call", 4),
      call: fixtures.local_call("owner_call"),
      replay:,
    )
  }
  assert hands.recover(owner_call(operation.ReplayNever))
    == effects.OutcomeUnknown
  assert hands.recover(owner_call(operation.ReplaySafe)) == effects.NotStarted
  assert fixtures.runs(probe) == []
  rig.stop(executor)
}

pub fn operator_directory_additions_are_refused_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let hands = attached(executor, store())

  let assert Error(reason) = hands.plane.resolve_directory("/anywhere", "read")

  assert string.contains(reason, "not supported")
  rig.stop(executor)
}

pub fn the_live_board_is_read_from_the_job_records_in_the_store_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()
  let hands = attached(executor, opened)
  let assert Ok(id) = jobstate.parse_job_id("job-1")
  let #(started_by, _) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  let record =
    jobstate.JobRecord(
      id:,
      owner: "main",
      started_by:,
      spec: jobstate.JobSpec(
        argv: ["sleep", "60"],
        cwd: rig.executor_root,
        requested_wall_ms: 60_000,
      ),
      started_at_ms: 400,
      deadline_ms: 60_400,
      state: jobstate.Running,
      spill: jobstate.no_spill(),
    )
  let assert Ok(_) =
    storage.commit(
      opened.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            register.FactCustom,
            jobstate.job_key(id),
            register.value(jobstate.encode(record)),
          ),
        ],
        expected: [],
      ),
    )

  let assert Ok(json.Object(board)) = hands.plane.live_jobs("main")

  assert list_get(board, "total") == json.Int(1)
  let assert json.Array([json.Object(row)]) = list_get(board, "jobs")
  assert list_get(row, "id") == json.String("job-1")
  assert list_get(row, "state") == json.String("running")
  assert list_get(row, "age_ms") == json.Int(600)
  let assert Ok(json.Object(other)) = hands.plane.live_jobs("other")
  assert list_get(other, "total") == json.Int(0)
  rig.stop(executor)
}

fn list_get(fields: List(#(String, json.JsonValue)), key: String) {
  let assert Ok(value) = list.key_find(fields, key)
  value
}

// Records the operation of `run` as running that call, the way the planner
// does before the effect starts.
fn holds_pending(opened: session.Session, run: effects.ToolRun) -> Nil {
  let generator = ids.generator(clock.fixed(at: 0), seed: 2)
  let #(entry, _) = ids.mint_entry(generator)
  let state =
    batch(run.step_id, [
      operation.CallEffectPending(
        source_index: run.source_index,
        result_entry: entry,
        replay: operation.ReplayNever,
      ),
    ])
  let assert Ok(_) =
    storage.commit(
      opened.store,
      tx.Tx(
        writes: [
          tx.SetRegister(
            register.OpState,
            ids.op_id_to_string(run.operation),
            register.value(codec.encode_state(state)),
          ),
        ],
        expected: [],
      ),
    )
    as "the operation state is recorded"
  Nil
}

// --- which calls this session still holds pending --------------------------

fn batch(
  turn_id: String,
  calls: List(operation.ToolCallState),
) -> operation.OperationState {
  let generator = ids.generator(clock.fixed(at: 0), seed: 9)
  let #(assistant, _) = ids.mint_entry(generator)
  operation.RunState(
    control: operation.Running,
    settings: operation.RunSettings(
      compaction: operation.CompactionSettings(
        enabled: False,
        reserve_tokens: 0,
        keep_recent_tokens: 0,
      ),
      steering_mode: operation.ConsumeAll,
      follow_up_mode: operation.ConsumeAll,
      tool_execution: operation.Parallel,
    ),
    phase: operation.Tools(batch: operation.ToolBatch(
      assistant_entry: assistant,
      configuration: strand.StrandConfiguration(
        model: strand.ModelIdentity(provider: "p", model_id: "m"),
        thinking_level: strand.ThinkingOff,
        active_tool_names: [],
      ),
      turn_id:,
      calls:,
    )),
    inbox: operation.Inbox(steer: [], follow_up: [], writes: []),
    latest_assistant: None,
  )
}

pub fn only_a_planned_or_running_call_of_the_step_is_pending_test() {
  let generator = ids.generator(clock.fixed(at: 0), seed: 5)
  let #(entry, _) = ids.mint_entry(generator)
  let state =
    batch("turn-1", [
      operation.CallCompleted(
        source_index: 0,
        result_entry: entry,
        terminate: False,
      ),
      operation.CallOutcomeReady(
        source_index: 1,
        result_entry: entry,
        terminate: False,
      ),
      operation.CallEffectPending(
        source_index: 2,
        result_entry: entry,
        replay: operation.ReplayNever,
      ),
      operation.CallPlanned(source_index: 3, result_entry: entry),
    ])

  assert !workspace.pending(state, "turn-1", 0)
  assert !workspace.pending(state, "turn-1", 1)
  assert workspace.pending(state, "turn-1", 2)
  assert workspace.pending(state, "turn-1", 3)

  // A call of another step, or one the batch does not list, is not pending.
  assert !workspace.pending(state, "turn-2", 2)
  assert !workspace.pending(state, "turn-1", 9)
}

pub fn a_call_of_a_finished_operation_is_settled_and_a_garbled_key_is_not_test() {
  let opened = store()
  let #(finished, _) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 4))
  let key =
    protocol.Key(
      session: "s",
      op: ids.op_id_to_string(finished),
      step: "turn-1",
      source_index: 0,
    )

  // The terminal transaction deletes the operation's state, so no state means
  // nothing of the operation is pending.
  assert workspace.settled(opened, key)
  assert !workspace.settled(opened, protocol.Key(..key, op: "not-an-op-id"))
}

// --- the hook wrappers keep the recovery slot ---------------------------------

fn remote_effects() -> effects.Effects {
  effects.Effects(
    clock: clock.fixed(1_700_000_000_000),
    entropy: fn() { 0 },
    timers: effects.Timers(after: fn(_delay, _wake) { Nil }),
    provider: effects.ProviderSurface(
      request: fn(_spec) { panic as "no request is made" },
      timeout_ms: 0,
    ),
    tools: effects.ToolSurface(
      clear: fn(_query) {
        effects.Cleared(
          effective_arguments: json.Object([]),
          replay: operation.ReplayNever,
        )
      },
      run: fn(_run) { panic as "no tool is run" },
      replay_still_safe: fn(_name) { False },
      execution_mode: fn(_name) { effects.ExclusiveExecution },
      recover: Some(fn(_run) { effects.OutcomeUnknown }),
    ),
    hooks: effects.default_hooks(),
  )
}

pub fn the_extension_bus_keeps_a_remote_surfaces_recovery_test() {
  let assert Ok(bus) = extension_hooks.start([], log.discard())
  let wired =
    extension_hooks.wire(remote_effects(), bus, store(), clock.fixed(at: 1000))

  let assert Some(recover) = wired.tools.recover
  assert recover(fixtures.tool_run("call_1", 0)) == effects.OutcomeUnknown
}

// --- closing the scope of a session that is not running ----------------------

pub fn a_scope_nobody_closed_is_closed_for_a_stopped_session_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()

  // The orchestrator died after attaching, so the scope is open on the executor
  // and the session's store never recorded a close.
  let first = attached(executor, opened)
  assert first.incarnation == 1

  assert workspace.close_stopped(
      rig.reach(executor),
      "registered-session",
      "registered-name",
      1,
    )
    == Ok(protocol.AllRetired)
  assert fixtures.closes(probe) == 1

  // Asking again, as a mover does after a lost reply or a restart, learns the
  // stored outcome and closes nothing a second time.
  assert workspace.close_stopped(
      rig.reach(executor),
      "registered-session",
      "registered-name",
      1,
    )
    == Ok(protocol.AllRetired)
  assert fixtures.closes(probe) == 1
  rig.stop(executor)
}

pub fn a_close_the_executor_could_not_prove_is_reported_as_it_ended_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.UnknownCleanup(2))
  let opened = store()
  let _first = attached(executor, opened)
  assert workspace.close_stopped(
      rig.reach(executor),
      "registered-session",
      "registered-name",
      1,
    )
    == Ok(protocol.UnknownCleanup(2))
  rig.stop(executor)
}

pub fn an_executor_that_refuses_the_close_is_told_apart_from_one_that_is_silent_test() {
  let probe = fixtures.probe(fixtures.Open)
  let executor = standard(probe, protocol.AllRetired)
  let opened = store()
  let _first = attached(executor, opened)

  // A close for an incarnation the executor does not hold is refused, and the
  // refusal says which one it does.
  assert workspace.close_stopped(
      rig.reach(executor),
      "registered-session",
      "registered-name",
      7,
    )
    == Error(workspace.CloseRefused(protocol.StaleIncarnation(1)))

  // An executor that cannot be connected to is not a refusal: the scope may
  // still be open, and the mover waits and asks again.
  assert workspace.close_stopped(
      workspace.Reach(..rig.reach(executor), connect: fn() { Error("down") }),
      "registered-session",
      "registered-name",
      1,
    )
    == Error(workspace.CloseUnanswered)
  assert fixtures.closes(probe) == 0
  rig.stop(executor)
}

pub fn an_execution_row_is_settled_only_once_its_record_is_closed_test() {
  let opened = store()
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 6))
  let standing_of = fn(standing) {
    workspace.settled_by_kind(
      opened,
      owner_port.Executions(..owner_port.no_executions(), standing: fn(_key) {
        standing
      }),
    )
  }
  let execution = protocol.execution_key("s", operation, "ab12")

  // The tool call rule would call this key settled at once, because no batch
  // lists an `async/` step. The record decides instead: a value the worker has
  // not read yet must not be acknowledged away.
  assert workspace.settled(opened, execution)
  assert !standing_of(owner_port.RecordLive)(execution)
  assert !standing_of(owner_port.RecordClosing)(execution)
  assert standing_of(owner_port.RecordClosed)(execution)

  // A tool call's key keeps the tool call rule whatever the records say.
  let call =
    protocol.Key(
      session: "s",
      op: ids.op_id_to_string(operation),
      step: "turn-1",
      source_index: 0,
    )
  assert standing_of(owner_port.RecordLive)(call)
}
