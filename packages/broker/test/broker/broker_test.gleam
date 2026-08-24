import broker/broker
import broker/budget
import broker/escalation
import broker/exec
import broker/policy
import broker/support/fake_helper
import broker/token
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/option.{Some}

fn op() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 3)
  let #(op_id, _) = ids.mint_op(generator)
  op_id
}

// A broker wired to one fake helper; checkins are observable on the
// returned subject.
fn broker_with(
  script: fake_helper.Script,
  at now: Int,
) -> #(broker.Broker, exec.Helper, Subject(exec.Helper)) {
  let helper = fake_helper.start_helper(script)
  let checkins = process.new_subject()
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: now),
        checkout: fn() { Ok(helper) },
        checkin: fn(helper) { process.send(checkins, helper) },
      ),
    )
  #(started, helper, checkins)
}

fn spec(op_id: ids.OpId) -> broker.CallSpec {
  broker.CallSpec(
    op_id:,
    step_id: "step-1",
    base_policy: policy.workspace_default("/work"),
    requirements: policy.workspace_default("/work"),
    grants: [],
    response: broker.RefuseNarrowed,
    demand: exec.BestEffort,
    argv: ["/bin/echo", "hi"],
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    budget: budget.Budget(max_outstanding: 4, deadline_ms: 100_000),
  )
}

pub fn clear_call_happy_path_test() {
  let #(started, _helper, checkins) =
    broker_with(fake_helper.EchoArgv, at: 1000)
  let events = process.new_subject()
  let assert Ok(_handle) =
    broker.clear_call(started, spec(op()), events:, waiting: 2000)
  let assert Ok(broker.CallOutput(data: <<"/bin/echo hi\n":utf8>>, ..)) =
    process.receive(events, 1000)
  let assert Ok(broker.CallSettled(broker.CallExited(result))) =
    process.receive(events, 1000)
  assert result.code == 0
  // Settlement returned the helper to the pool seam.
  let assert Ok(_) = process.receive(checkins, 1000)
  broker.stop(started)
}

pub fn policy_narrowing_refused_with_denial_test() {
  let #(started, _helper, _checkins) =
    broker_with(fake_helper.EchoArgv, at: 1000)
  let wants_more =
    policy.SandboxPolicy(..policy.workspace_default("/work"), writable_roots: [
      "/etc",
    ])
  let refusing = broker.CallSpec(..spec(op()), requirements: wants_more)
  let events = process.new_subject()
  let assert Error(broker.PolicyRefused(denial)) =
    broker.clear_call(started, refusing, events:, waiting: 2000)
  // The denial carries the exact diff an approval would grant, ready
  // for escalation.raise.
  assert denial.wanted == [policy.GrantWritableRoot(path: "/etc")]
  assert denial.source == escalation.PolicyDenial
  // Nothing was dispatched.
  assert process.receive(events, 200) == Error(Nil)
  broker.stop(started)
}

pub fn grants_widen_explicitly_test() {
  let #(started, _helper, _checkins) =
    broker_with(fake_helper.EchoArgv, at: 1000)
  let wants_more =
    policy.SandboxPolicy(..policy.workspace_default("/work"), writable_roots: [
      "/etc",
    ])
  let granted =
    broker.CallSpec(..spec(op()), requirements: wants_more, grants: [
      policy.GrantWritableRoot(path: "/etc"),
    ])
  let events = process.new_subject()
  let assert Ok(_handle) =
    broker.clear_call(started, granted, events:, waiting: 2000)
  let assert Ok(broker.CallOutput(..)) = process.receive(events, 1000)
  let assert Ok(broker.CallSettled(broker.CallExited(_))) =
    process.receive(events, 1000)
  broker.stop(started)
}

pub fn budget_deadline_refused_test() {
  let #(started, _helper, _checkins) =
    broker_with(fake_helper.EchoArgv, at: 5000)
  let expired =
    broker.CallSpec(
      ..spec(op()),
      budget: budget.Budget(max_outstanding: 1, deadline_ms: 4000),
    )
  let events = process.new_subject()
  assert broker.clear_call(started, expired, events:, waiting: 2000)
    == Error(
      broker.BudgetRefused(refusal: budget.DeadlinePassed(deadline_ms: 4000)),
    )
  broker.stop(started)
}

pub fn abort_revokes_and_cancels_test() {
  let #(started, _helper, checkins) =
    broker_with(fake_helper.SleepUntilCancel, at: 1000)
  let op_id = op()
  let events = process.new_subject()
  let assert Ok(_handle) =
    broker.clear_call(started, spec(op_id), events:, waiting: 2000)
  // Nothing has settled yet: the execution is sleeping.
  assert process.receive(events, 200) == Error(Nil)
  broker.abort(started, op_id)
  // The cancel reaches the helper; the fake settles with signal 15.
  let assert Ok(broker.CallSettled(broker.CallExited(result))) =
    process.receive(events, 2000)
  assert result.signal == 15
  let assert Ok(_) = process.receive(checkins, 1000)
  broker.stop(started)
}

pub fn degraded_dispatch_settles_in_band_test() {
  let #(started, _helper, checkins) =
    broker_with(fake_helper.Degraded, at: 1000)
  let demanding = broker.CallSpec(..spec(op()), demand: exec.FullEnforcement)
  let events = process.new_subject()
  // Authorization succeeds; the dispatch-stage refusal arrives as the
  // one settlement event.
  let assert Ok(_handle) =
    broker.clear_call(started, demanding, events:, waiting: 2000)
  let assert Ok(broker.CallSettled(broker.CallFailed(failure))) =
    process.receive(events, 2000)
  let assert exec.DegradedHelper(_) = failure
  // The failure converts to a structured denial for escalation.
  let assert Some(denial) = broker.denial_for_failure(failure)
  let assert escalation.ExecutionDenial(_) = denial.source
  // The helper still went back to the pool.
  let assert Ok(_) = process.receive(checkins, 1000)
  broker.stop(started)
}

pub fn stdin_flows_through_handle_test() {
  let #(started, _helper, _checkins) =
    broker_with(fake_helper.StdinEcho, at: 1000)
  let events = process.new_subject()
  let assert Ok(handle) =
    broker.clear_call(started, spec(op()), events:, waiting: 2000)
  broker.stdin(started, handle, data: <<"in ">>, eof: False)
  broker.stdin(started, handle, data: <<"out">>, eof: True)
  let assert Ok(broker.CallOutput(data: <<"in out":utf8>>, ..)) =
    process.receive(events, 1000)
  let assert Ok(broker.CallSettled(broker.CallExited(_))) =
    process.receive(events, 1000)
  broker.stop(started)
}

pub fn wall_deadline_cancels_execution_test() {
  // A stepping clock: authorization reads t=1000 (inside the deadline),
  // the relay's next read is past it, so the relay cancels.
  let helper = fake_helper.start_helper(fake_helper.SleepUntilCancel)
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.stepping(from: 1000, by: 300),
        checkout: fn() { Ok(helper) },
        checkin: fn(_helper) { Nil },
      ),
    )
  let bounded =
    broker.CallSpec(
      ..spec(op()),
      budget: budget.Budget(max_outstanding: 1, deadline_ms: 1100),
    )
  let events = process.new_subject()
  let assert Ok(_handle) =
    broker.clear_call(started, bounded, events:, waiting: 2000)
  let assert Ok(broker.CallSettled(broker.CallExited(result))) =
    process.receive(events, 3000)
  assert result.signal == 15
  broker.stop(started)
}

pub fn cancel_through_handle_test() {
  let #(started, _helper, _checkins) =
    broker_with(fake_helper.SleepUntilCancel, at: 1000)
  let events = process.new_subject()
  let assert Ok(handle) =
    broker.clear_call(started, spec(op()), events:, waiting: 2000)
  broker.cancel(started, handle)
  let assert Ok(broker.CallSettled(broker.CallExited(result))) =
    process.receive(events, 2000)
  assert result.signal == 15
  // Cancel after settlement is a harmless no-op.
  broker.cancel(started, handle)
  broker.stop(started)
}
