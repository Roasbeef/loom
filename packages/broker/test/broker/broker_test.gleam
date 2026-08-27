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
import gleam/string

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

// A broker whose checkout seam spawns a fresh fake helper per call, so
// concurrency is bounded only by the pooled budget under test.
fn broker_with_fresh_helpers(
  script: fake_helper.Script,
  at now: Int,
) -> #(broker.Broker, Subject(exec.Helper)) {
  let checkins = process.new_subject()
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: now),
        checkout: fn() { Ok(fake_helper.start_helper(script)) },
        checkin: fn(helper) { process.send(checkins, helper) },
      ),
    )
  #(started, checkins)
}

fn capped_spec(op_id: ids.OpId, cap: Int) -> broker.CallSpec {
  broker.CallSpec(
    ..spec(op_id),
    budget: budget.Budget(max_outstanding: cap, deadline_ms: 100_000),
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

// --- pooled per-execution budget ----------------------------------------

pub fn budget_cap_refuses_excess_concurrent_calls_test() {
  let #(started, _checkins) =
    broker_with_fresh_helpers(fake_helper.SleepUntilCancel, at: 1000)
  let op_id = op()
  let pooled = capped_spec(op_id, 2)
  let events = process.new_subject()
  let assert Ok(_first) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Ok(_second) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  // A third concurrent effect under the same {op_id, step_id}: the
  // pooled ledger is at its cap, however politely it asks.
  assert broker.clear_call(started, pooled, events:, waiting: 2000)
    == Error(
      broker.BudgetRefused(refusal: budget.OutstandingCapReached(cap: 2)),
    )
  // A different step is a different execution with its own ledger.
  let other_step = broker.CallSpec(..pooled, step_id: "step-2")
  let assert Ok(_other) =
    broker.clear_call(started, other_step, events:, waiting: 2000)
  broker.abort(started, op_id)
  broker.stop(started)
}

pub fn settling_one_call_frees_exactly_one_slot_test() {
  let #(started, _checkins) =
    broker_with_fresh_helpers(fake_helper.SleepUntilCancel, at: 1000)
  let op_id = op()
  let pooled = capped_spec(op_id, 2)
  let events = process.new_subject()
  let assert Ok(first) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Ok(_second) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Error(broker.BudgetRefused(_)) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  // Settle the first call; its slot (and only its slot) frees.
  broker.cancel(started, first)
  let assert Ok(broker.CallSettled(broker.CallExited(result))) =
    process.receive(events, 2000)
  assert result.signal == 15
  let assert Ok(_third) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Error(broker.BudgetRefused(_)) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  broker.abort(started, op_id)
  broker.stop(started)
}

pub fn abort_frees_all_op_reservations_test() {
  let #(started, _checkins) =
    broker_with_fresh_helpers(fake_helper.SleepUntilCancel, at: 1000)
  let op_id = op()
  let pooled = capped_spec(op_id, 2)
  let events = process.new_subject()
  let assert Ok(_first) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Ok(_second) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Error(broker.BudgetRefused(_)) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  // Abort frees the whole operation's reservations at once...
  broker.abort(started, op_id)
  let assert Ok(_third) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Ok(_fourth) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  // ...and the late settlements of the aborted calls (arriving now,
  // signal 15) release nothing from the successor ledger.
  let assert Ok(broker.CallSettled(broker.CallExited(_))) =
    process.receive(events, 2000)
  let assert Ok(broker.CallSettled(broker.CallExited(_))) =
    process.receive(events, 2000)
  let assert Error(broker.BudgetRefused(_)) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  broker.abort(started, op_id)
  broker.stop(started)
}

pub fn relay_death_reclaims_slot_and_helper_test() {
  let #(started, checkins) =
    broker_with_fresh_helpers(fake_helper.SleepUntilCancel, at: 1000)
  let op_id = op()
  let pooled = capped_spec(op_id, 1)
  let events = process.new_subject()
  let assert Ok(first) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Error(broker.BudgetRefused(_)) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  // Kill the call's relay outright: no settlement will ever arrive,
  // and the broker must reclaim everything the call held.
  let assert Ok(relay) = broker.relay_pid(started, first, waiting: 1000)
  process.kill(relay)
  // The helper went back to the pool seam...
  let assert Ok(_helper) = process.receive(checkins, 2000)
  // ...and the budget slot is free again.
  let assert Ok(_second) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  broker.abort(started, op_id)
  broker.stop(started)
}

// --- network proxy mode fails closed (phase 1) --------------------------

fn proxy_network() -> policy.NetworkPolicy {
  policy.NetworkProxy(allow: ["registry.npmjs.org"], proxy: "127.0.0.1:3128")
}

pub fn proxy_mode_refused_with_structured_denial_test() {
  let #(started, _helper, _checkins) =
    broker_with(fake_helper.EchoNetwork, at: 1000)
  let asking =
    policy.SandboxPolicy(
      ..policy.workspace_default("/work"),
      network: proxy_network(),
    )
  let refusing =
    broker.CallSpec(..spec(op()), base_policy: asking, requirements: asking)
  let events = process.new_subject()
  let assert Error(broker.PolicyRefused(denial)) =
    broker.clear_call(started, refusing, events:, waiting: 2000)
  // The denial names the unimplemented capability and carries the
  // exact unenforceable grant.
  assert string.contains(denial.reason, "phase 1")
  assert denial.wanted == [policy.GrantNetwork(network: proxy_network())]
  // Nothing was dispatched.
  assert process.receive(events, 200) == Error(Nil)
  broker.stop(started)
}

pub fn proxy_mode_proceeds_with_network_off_test() {
  let #(started, _helper, _checkins) =
    broker_with(fake_helper.EchoNetwork, at: 1000)
  let asking =
    policy.SandboxPolicy(
      ..policy.workspace_default("/work"),
      network: proxy_network(),
    )
  let proceeding =
    broker.CallSpec(
      ..spec(op()),
      base_policy: asking,
      requirements: asking,
      response: broker.ProceedNarrowed,
    )
  let events = process.new_subject()
  let assert Ok(_handle) =
    broker.clear_call(started, proceeding, events:, waiting: 2000)
  // The execution's effective network is off — never the unrestricted
  // egress a phase-1 proxy jail would silently have.
  let assert Ok(broker.CallOutput(data: <<"off\n":utf8>>, ..)) =
    process.receive(events, 1000)
  let assert Ok(broker.CallSettled(broker.CallExited(_))) =
    process.receive(events, 1000)
  broker.stop(started)
}

pub fn full_mode_unaffected_by_proxy_downgrade_test() {
  let #(started, _helper, _checkins) =
    broker_with(fake_helper.EchoNetwork, at: 1000)
  let open =
    policy.SandboxPolicy(
      ..policy.workspace_default("/work"),
      network: policy.NetworkFull,
    )
  let full =
    broker.CallSpec(..spec(op()), base_policy: open, requirements: open)
  let events = process.new_subject()
  let assert Ok(_handle) =
    broker.clear_call(started, full, events:, waiting: 2000)
  let assert Ok(broker.CallOutput(data: <<"full\n":utf8>>, ..)) =
    process.receive(events, 1000)
  let assert Ok(broker.CallSettled(broker.CallExited(_))) =
    process.receive(events, 1000)
  broker.stop(started)
}

pub fn off_mode_unaffected_by_proxy_downgrade_test() {
  let #(started, _helper, _checkins) =
    broker_with(fake_helper.EchoNetwork, at: 1000)
  let events = process.new_subject()
  let assert Ok(_handle) =
    broker.clear_call(started, spec(op()), events:, waiting: 2000)
  let assert Ok(broker.CallOutput(data: <<"off\n":utf8>>, ..)) =
    process.receive(events, 1000)
  let assert Ok(broker.CallSettled(broker.CallExited(_))) =
    process.receive(events, 1000)
  broker.stop(started)
}

// --- a full pool is congestion, not a refusal ----------------------------

// A broker over a real pool of `size` fake helpers, so exhaustion is the
// pool's own `AllBusy` rather than a seam that pretends.
fn broker_over_pool(
  script: fake_helper.Script,
  size size: Int,
) -> #(broker.Broker, exec.Pool) {
  let assert Ok(pool) =
    exec.start_pool(size:, spawn: fn() { Ok(fake_helper.start_helper(script)) })
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 1000),
        checkout: fn() { exec.checkout(pool, waiting: 2000) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
      ),
    )
  #(started, pool)
}

// Clears a call from a process of its own and reports the verdict, so a
// caller that waits for pool capacity can be observed waiting.
fn clear_elsewhere(
  started: broker.Broker,
  spec: broker.CallSpec,
  waiting timeout: Int,
) -> Subject(Result(broker.CallHandle, broker.Refusal)) {
  let verdicts = process.new_subject()
  process.spawn_unlinked(fn() {
    let events = process.new_subject()
    process.send(
      verdicts,
      broker.clear_call(started, spec, events:, waiting: timeout),
    )
  })
  verdicts
}

/// A second call against a one-helper pool waits for the first to settle
/// instead of coming back `NoHelper` — the batch-wider-than-the-pool
/// case, which is the whole reason a parallel batch is not capped by the
/// pool's size. It is also the deadlock proof: the wait can only end
/// because the broker went on processing the settlement of the very call
/// whose helper is being waited for.
pub fn a_full_pool_waits_for_a_settlement_test() {
  let #(started, pool) = broker_over_pool(fake_helper.SleepUntilCancel, size: 1)
  let events = process.new_subject()
  let assert Ok(first) =
    broker.clear_call(started, spec(op()), events:, waiting: 5000)
  // The only helper is lent out. The second call is *waiting*: no
  // verdict of any kind has been handed back.
  let verdicts = clear_elsewhere(started, spec(op()), waiting: 5000)
  assert process.receive(verdicts, 300) == Error(Nil)
  // Settling the first call frees the helper, and the waiter takes it.
  broker.cancel(started, first)
  let assert Ok(broker.CallSettled(broker.CallExited(_))) =
    process.receive(events, 3000)
  let assert Ok(Ok(_second)) = process.receive(verdicts, 3000)
  broker.stop(started)
  exec.stop_pool(pool)
}

/// The wait is bounded, not indefinite: a caller that gives clearance a
/// short budget still gets its answer, and the answer still names the
/// pool. This is what keeps a nested borrower degrading into today's
/// refusal rather than into a stall.
///
/// The budget here is deliberately a little over the window the loop
/// reserves for its last attempt, so the caller does wait for a while
/// before it gives up rather than declining to wait at all.
pub fn a_full_pool_still_refuses_once_the_budget_is_spent_test() {
  let #(started, pool) = broker_over_pool(fake_helper.SleepUntilCancel, size: 1)
  let events = process.new_subject()
  let assert Ok(_first) =
    broker.clear_call(started, spec(op()), events:, waiting: 5000)
  let verdicts = clear_elsewhere(started, spec(op()), waiting: 1400)
  let assert Ok(Error(broker.NoHelper(error: exec.AllBusy(size: 1)))) =
    process.receive(verdicts, 3000)
  broker.stop(started)
  exec.stop_pool(pool)
}

/// A pool that lends nothing is not congested — nothing is running, so
/// nothing will be checked back in — and waiting on one would only spend
/// the caller's whole clearance budget to reach the same answer. The
/// refusal comes straight back.
pub fn a_pool_that_lends_nothing_refuses_at_once_test() {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 1000),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
  // The clearance budget is five seconds; the verdict must not take it.
  let verdicts = clear_elsewhere(started, spec(op()), waiting: 5000)
  let assert Ok(Error(broker.NoHelper(error: exec.AllBusy(size: 0)))) =
    process.receive(verdicts, 500)
  broker.stop(started)
}

/// Waiting for a helper holds nothing. The broker's checkout-failure
/// path hands the reserved budget slot back and revokes the minted token
/// before it answers, so a caller parked on a full pool is not silently
/// spending the execution's pooled `max_outstanding` while it waits.
/// The probe is a third call under a ledger capped at two: if the parked
/// caller still held a slot it would be refused by the *budget*, and
/// instead it gets all the way to the pool.
pub fn a_waiting_call_holds_no_budget_slot_test() {
  let #(started, pool) = broker_over_pool(fake_helper.SleepUntilCancel, size: 1)
  let op_id = op()
  let two_at_a_time = capped_spec(op_id, 2)
  let events = process.new_subject()
  let assert Ok(first) =
    broker.clear_call(started, two_at_a_time, events:, waiting: 5000)
  let parked = clear_elsewhere(started, two_at_a_time, waiting: 5000)
  assert process.receive(parked, 300) == Error(Nil)
  // The ledger's second slot is free, so the probe reaches the pool and
  // is turned away by *it* — the parked caller is holding neither.
  let probe = clear_elsewhere(started, two_at_a_time, waiting: 120)
  let assert Ok(Error(broker.NoHelper(error: exec.AllBusy(size: 1)))) =
    process.receive(probe, 3000)
  // And the parked caller still gets its helper when one comes back.
  broker.cancel(started, first)
  let assert Ok(broker.CallSettled(broker.CallExited(_))) =
    process.receive(events, 3000)
  let assert Ok(Ok(_second)) = process.receive(parked, 3000)
  broker.stop(started)
  exec.stop_pool(pool)
}

/// An abort that lands while a clearance is waiting out a congested
/// pool must refuse that clearance, not let it dispatch afterwards.
/// This is the window the congestion wait opened: `abort` revokes the
/// operation's tokens and cancels its running calls in one sweep, so a
/// retry that woke up afterwards would compose a fresh policy, open a
/// fresh ledger, mint a token the sweep never saw, and start a jailed
/// execution with nothing left to cancel it.
///
/// The pool here never lends, so without the epoch check the caller
/// would sit for its whole five-second budget and answer `NoHelper`.
/// Answering `OperationAborted` in a fraction of that is the proof that
/// the retry was refused for the right reason.
pub fn an_abort_during_a_congestion_wait_refuses_the_retry_test() {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 1000),
        checkout: fn() { Error(exec.AllBusy(size: 2)) },
        checkin: fn(_helper) { Nil },
      ),
    )
  let op_id = op()
  let verdicts = clear_elsewhere(started, spec(op_id), waiting: 5000)
  // Let the caller reach its wait, then abort underneath it.
  process.sleep(80)
  broker.abort(started, op_id)
  let assert Ok(Error(broker.OperationAborted)) =
    process.receive(verdicts, 2000)
  broker.stop(started)
}

/// A checkout seam slower than what is left of the caller's budget must
/// produce an in-band refusal, not a dead borrower.
///
/// The arithmetic gets there on its own: a 100 ms budget against a 60 ms
/// seam leaves 40 ms after the first attempt, and a nap of 25 takes the
/// next attempt's window to 15 — against a broker that demonstrably
/// needs 60. `process.call` panics on a timeout, so the retry used to
/// kill the borrower and hand back no verdict at all. The borrower here
/// is a strand effect process: its death is a synthetic zero-usage
/// abort, where `NoHelper` is something the model can read and route
/// around.
///
/// The loop therefore reserves a window it believes the broker can
/// answer in and stops rather than spending its last milliseconds on an
/// exchange it expects to lose.
pub fn a_slow_seam_refuses_in_band_rather_than_killing_the_caller_test() {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 1000),
        checkout: fn() {
          process.sleep(60)
          Error(exec.AllBusy(size: 2))
        },
        checkin: fn(_helper) { Nil },
      ),
    )
  let verdicts = clear_elsewhere(started, spec(op()), waiting: 100)
  let assert Ok(Error(broker.NoHelper(error: exec.AllBusy(size: 2)))) =
    process.receive(verdicts, 3000)
  broker.stop(started)
}

/// A broker that does not answer within the caller's whole budget is
/// still a verdict. `clear_call`'s exchange is a `try_call` precisely so
/// that the one caller holding the refusal cannot lose it by dying of
/// the wait — and the broker legitimately blocks for seconds at a time
/// on a checkout seam or a relay handshake, so this is congestion
/// wearing a different hat rather than a broken broker.
pub fn a_broker_that_never_answers_refuses_rather_than_panicking_test() {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 1000),
        checkout: fn() {
          process.sleep(2000)
          Error(exec.AllBusy(size: 2))
        },
        checkin: fn(_helper) { Nil },
      ),
    )
  let verdicts = clear_elsewhere(started, spec(op()), waiting: 150)
  assert process.receive(verdicts, 3000) == Ok(Error(broker.BrokerUnavailable))
  broker.stop(started)
}

/// A broker that stops underneath a parked waiter answers it. The wait
/// is a loop of exchanges, and this PR widened the window in which one
/// of them can land on a broker that has since stopped from a single
/// round trip to the caller's whole budget. `process.call` panics on a
/// dead callee; the waiter needs to settle its effect instead.
pub fn a_waiter_outliving_the_broker_refuses_rather_than_panicking_test() {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 1000),
        checkout: fn() { Error(exec.AllBusy(size: 2)) },
        checkin: fn(_helper) { Nil },
      ),
    )
  let verdicts = clear_elsewhere(started, spec(op()), waiting: 30_000)
  // Let the caller reach its wait, then stop the broker underneath it.
  process.sleep(80)
  broker.stop(started)
  assert process.receive(verdicts, 3000) == Ok(Error(broker.BrokerUnavailable))
}

// --- the broker outlives what it borrows from ---------------------------

// A broker over a real pool whose helpers take `spawning` milliseconds
// to start, borrowing with a `waiting` window of its own. Both knobs
// exist to make the pool miss that window on purpose.
fn broker_over_slow_pool(
  spawning spawn_ms: Int,
  waiting checkout_ms: Int,
) -> #(broker.Broker, exec.Pool) {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      process.sleep(spawn_ms)
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 1000),
        checkout: fn() { exec.checkout(pool, waiting: checkout_ms) },
        checkin: fn(helper) { exec.checkin(pool, helper) },
      ),
    )
  #(started, pool)
}

/// A pool that has stopped is a refusal, not the broker's death. The
/// broker calls its checkout seam synchronously inside its own message
/// handler, so the panic `process.call` used to raise there did not
/// cost one clearance — it cost every in-flight strand's verdict, each
/// of which settles as a synthetic zero-usage abort when its effect
/// process dies with the broker.
///
/// Surviving is the assertion: an error value proves nothing on its own
/// if the process that produced it is gone, so the broker's own pid is
/// checked, and then asked for a second verdict.
pub fn a_broker_outlives_a_pool_that_stopped_test() {
  let #(started, pool) = broker_over_slow_pool(spawning: 0, waiting: 1000)
  exec.stop_pool(pool)
  // Let the pool actor actually go before the broker borrows from it.
  process.sleep(100)
  let events = process.new_subject()
  assert broker.clear_call(started, spec(op()), events:, waiting: 2000)
    == Error(broker.NoHelper(error: exec.PoolUnavailable))
  let assert Ok(broker_pid) = broker.pid(started)
  assert process.is_alive(broker_pid)
  // Still a broker, not merely a live process.
  assert broker.clear_call(started, spec(op()), events:, waiting: 2000)
    == Error(broker.NoHelper(error: exec.PoolUnavailable))
  broker.stop(started)
}

/// A pool that is alive and answering nothing reaches the same place.
/// Spawning runs inside the pool actor, so a helper slower to start
/// than the broker's borrowing window leaves the broker with no reply
/// at all — the timeout half of `process.call`'s panic, and the half a
/// live-but-wedged pool actually produces.
///
/// The timing is the second assertion. A wedged pool is not a full one:
/// congestion clears as running executions end and is worth waiting
/// out, while re-asking an unanswering pool spends the caller's whole
/// clearance budget to arrive at the same refusal. The verdict must
/// come back in a fraction of the five seconds this caller was willing
/// to wait.
pub fn a_broker_outlives_a_pool_that_will_not_answer_test() {
  let #(started, pool) = broker_over_slow_pool(spawning: 3000, waiting: 150)
  let verdicts = clear_elsewhere(started, spec(op()), waiting: 5000)
  let assert Ok(Error(broker.NoHelper(error: exec.PoolUnavailable))) =
    process.receive(verdicts, 800)
  let assert Ok(broker_pid) = broker.pid(started)
  assert process.is_alive(broker_pid)
  broker.stop(started)
  exec.stop_pool(pool)
}

/// The borrow and the dispatch are two exchanges, and the helper is
/// free to die between them: the pool lends what it last probed, and
/// the broker dispatches to it a few microseconds later from inside the
/// same handler. That gap used to be fatal to the broker. It settles in
/// band now — one `CallSettled` carrying the dispatch failure, exactly
/// as a helper's own refusal would.
pub fn a_broker_outlives_a_helper_that_died_before_dispatch_test() {
  let #(started, helper, _checkins) =
    broker_with(fake_helper.EchoArgv, at: 1000)
  exec.shutdown(helper)
  await_departed(exec.pid(helper))
  let events = process.new_subject()
  let assert Ok(_handle) =
    broker.clear_call(started, spec(op()), events:, waiting: 2000)
  let assert Ok(broker.CallSettled(broker.CallFailed(exec.HelperUnresponsive))) =
    process.receive(events, 2000)
  let assert Ok(broker_pid) = broker.pid(started)
  assert process.is_alive(broker_pid)
  broker.stop(started)
}

// Waits until a shut-down helper actor has actually exited, so a test
// that means "the callee is gone" is not racing the shutdown.
fn await_departed(pid: process.Pid) -> Nil {
  case process.is_alive(pid) {
    False -> Nil
    True -> {
      process.sleep(20)
      await_departed(pid)
    }
  }
}

/// A clearance begun *after* an abort is an ordinary clearance. `abort`
/// is a scoped cancel rather than a terminal verdict on the operation —
/// code mode aborts the strand's own operation on every teardown, the
/// successful ones included — so a fresh call under the same key must
/// still run. Only a clearance resuming across the abort is refused.
pub fn a_clearance_begun_after_an_abort_still_runs_test() {
  let #(started, _checkins) =
    broker_with_fresh_helpers(fake_helper.EchoArgv, at: 1000)
  let op_id = op()
  let events = process.new_subject()
  broker.abort(started, op_id)
  let assert Ok(_handle) =
    broker.clear_call(started, spec(op_id), events:, waiting: 2000)
  broker.stop(started)
}
