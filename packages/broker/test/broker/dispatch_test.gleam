import broker/broker
import broker/budget
import broker/dispatch
import broker/exec
import broker/framing
import broker/policy
import broker/token
import core/clock
import core/ids
import core/remote_tool
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}

// These tests drive the broker through a hand-written `Dispatcher`, so what
// is under test is the broker's side of the seam alone: which closures it
// calls, how often, and what it releases. No helper, relay or pool exists.

// What the fake dispatcher saw, in the order it saw it.
type Observed {
  Started(request: dispatch.Dispatch, guarantor: Pid)
  Cancelled
  Stdin(data: BitArray, eof: dispatch.Eof)
  Released
  Abandoned
}

fn op() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 5)
  let #(op_id, _) = ids.mint_op(generator)
  op_id
}

fn capped_spec(op_id: ids.OpId, cap: Int) -> broker.CallSpec {
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
    budget: budget.Budget(max_outstanding: cap, deadline_ms: 100_000),
  )
}

// A dispatcher that starts nothing real. Each started execution has a
// guarantor process that does nothing until the test kills it, and reports
// every closure the broker calls on `observed`. A `Some` refusal makes
// every start refuse instead.
fn fake(
  observed: Subject(Observed),
  refusing refusal: Option(dispatch.StartRefusal),
) -> dispatch.Dispatcher {
  dispatch.Dispatcher(start: fn(request) {
    case refusal {
      Some(refusal) -> Error(refusal)
      None -> {
        let guarantor = process.spawn_unlinked(process.sleep_forever)
        process.send(observed, Started(request:, guarantor:))
        Ok(
          dispatch.Execution(
            id: dispatch.execution_id(incarnation: 9, seq: request.seq),
            guarantor:,
            cancel: fn() { process.send(observed, Cancelled) },
            stdin: fn(data, eof) { process.send(observed, Stdin(data:, eof:)) },
            release: fn() { process.send(observed, Released) },
            abandon: fn() { process.send(observed, Abandoned) },
          ),
        )
      }
    }
  })
}

fn broker_over(dispatcher: dispatch.Dispatcher) -> broker.Broker {
  let assert Ok(started) =
    broker.start_dispatching(
      entropy: token.production_entropy(),
      clock: clock.fixed(at: 1000),
      dispatcher:,
    )
  started
}

fn exit_result() -> exec.ExecResult {
  exec.ExecResult(
    code: 0,
    signal: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: [],
    degraded: False,
    wall_ms: 1,
    timed_out: False,
    cancelled: False,
  )
}

// Receives the next observation or fails the test with a name for what
// was missing.
fn next(observed: Subject(Observed)) -> Observed {
  let assert Ok(seen) = process.receive(observed, 2000)
    as "the fake dispatcher saw nothing"
  seen
}

pub fn clear_call_hands_the_dispatcher_a_complete_dispatch_test() {
  let observed = process.new_subject()
  let started = broker_over(fake(observed, refusing: None))
  let events = process.new_subject()
  let spec = capped_spec(op(), 4)
  let assert Ok(_handle) =
    broker.clear_call(started, spec, events:, waiting: 2000)

  // The deadline is the pooled budget's, the sequence is the broker's
  // first call id, and the caller is the process that owns `events`.
  let assert Started(request:, guarantor: _) = next(observed)
  assert request.context
    == dispatch.CallContext(
      operation: spec.op_id,
      step: spec.step_id,
      origin: None,
    )
  assert request.deadline_ms == 100_000
  assert request.seq == 1
  assert request.caller == Some(process.self())
  assert request.request.argv == ["/bin/echo", "hi"]
  broker.stop(started)
}

pub fn cancel_stdin_and_abort_reach_the_execution_closures_test() {
  let observed = process.new_subject()
  let started = broker_over(fake(observed, refusing: None))
  let op_id = op()
  let events = process.new_subject()
  let assert Ok(handle) =
    broker.clear_call(started, capped_spec(op_id, 4), events:, waiting: 2000)
  let assert Started(..) = next(observed)

  // A cancel names the execution, once per request.
  broker.cancel(started, handle)
  assert next(observed) == Cancelled

  // Stdin carries its bytes and whether they are the last.
  broker.stdin(started, handle, data: <<"more">>, eof: False)
  assert next(observed) == Stdin(<<"more">>, dispatch.MoreInput)
  broker.stdin(started, handle, data: <<"last">>, eof: True)
  assert next(observed) == Stdin(<<"last">>, dispatch.EndOfInput)

  // An abort of the operation cancels the executions under it, and an
  // abort of some other step does not.
  broker.abort_step(started, op_id, step_id: "another-step")
  assert process.receive(observed, 100) == Error(Nil)
  broker.abort_step(started, op_id, step_id: "step-1")
  assert next(observed) == Cancelled
  broker.abort(started, op_id)
  assert next(observed) == Cancelled
  broker.stop(started)
}

pub fn unsettled_guarantor_death_abandons_once_and_frees_the_slot_test() {
  let observed = process.new_subject()
  let started = broker_over(fake(observed, refusing: None))
  let pooled = capped_spec(op(), 1)
  let events = process.new_subject()
  let assert Ok(first) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Started(request: _, guarantor:) = next(observed)

  // The slot is held while the execution lives.
  let assert Error(broker.BudgetRefused(_)) =
    broker.clear_call(started, pooled, events:, waiting: 2000)

  // The broker reports the guarantor it was given.
  let assert Ok(reported) = broker.relay_pid(started, first, waiting: 1000)
  assert reported == guarantor

  // The guarantor dies without settling: the broker abandons the
  // execution exactly once and the slot comes back.
  process.kill(guarantor)
  assert next(observed) == Abandoned

  // The unsettled path returns what was lent through `abandon` alone:
  // no `release` follows it, and no second `abandon`.
  assert process.receive(observed, 200) == Error(Nil)
  let assert Ok(_second) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  broker.stop(started)
}

pub fn settling_releases_once_and_never_abandons_test() {
  let observed = process.new_subject()
  let started = broker_over(fake(observed, refusing: None))
  let pooled = capped_spec(op(), 1)
  let events = process.new_subject()
  let assert Ok(handle) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Started(request:, guarantor:) = next(observed)

  // Output is delivered to the caller, then the terminal verdict, in the
  // order the dispatcher produced them.
  request.deliver(dispatch.Chunk(
    stream: framing.Stdout,
    data: <<"out">>,
    total_bytes: 3,
    truncated: False,
  ))
  request.settle(dispatch.Completed(result: exit_result()))
  let assert Ok(broker.CallOutput(framing.Stdout, <<"out">>, 3, False)) =
    process.receive(events, 2000)
  let assert Ok(broker.CallSettled(broker.CallExited(result))) =
    process.receive(events, 2000)
  assert result == exit_result()

  // Settling is what makes the broker return what the dispatcher lent:
  // `release` runs once, while the broker handles the `Settle`.
  assert next(observed) == Released

  // The slot is free and the call is gone from the active table, so the
  // guarantor's exit that follows settlement is not an unsettled death.
  let assert Ok(_second) =
    broker.clear_call(started, pooled, events:, waiting: 2000)
  let assert Started(request: second_request, guarantor: second) =
    next(observed)
  assert broker.relay_pid(started, handle, waiting: 1000) == Error(Nil)
  process.kill(guarantor)
  assert process.receive(observed, 300) == Error(Nil)

  // A failure settles as a failed outcome, and it too leaves nothing for
  // the guarantor's later exit to abandon.
  second_request.settle(dispatch.Failed(failure: exec.CancelEscalated))
  let assert Ok(broker.CallSettled(broker.CallFailed(exec.CancelEscalated))) =
    process.receive(events, 2000)
  assert next(observed) == Released
  process.kill(second)
  assert process.receive(observed, 300) == Error(Nil)
  broker.stop(started)
}

pub fn a_refused_start_maps_to_the_refusals_it_replaced_test() {
  let pool_busy = exec.AllBusy(size: 2)
  let observed = process.new_subject()
  let pooled = capped_spec(op(), 1)
  let events = process.new_subject()

  // No helper: the pool's own verdict reaches the caller unchanged, and
  // the slot is not left held (a second attempt is refused for the same
  // reason, not for budget).
  //
  // The budget is a second, not less, because a congested answer under a
  // second is returned without a retry (`min_retry_window_ms`), so the one
  // exchange gets the whole window. A shorter one timed that exchange out
  // when eight modules shared the emulator, and the caller heard
  // `BrokerUnavailable` instead of the pool's verdict.
  let busy =
    broker_over(fake(observed, refusing: Some(dispatch.NoHelper(pool_busy))))
  let assert Error(broker.NoHelper(exec.AllBusy(size: 2))) =
    broker.clear_call(busy, pooled, events:, waiting: 1000)
  let assert Error(broker.NoHelper(exec.AllBusy(size: 2))) =
    broker.clear_call(busy, pooled, events:, waiting: 1000)
  broker.stop(busy)

  // A dispatcher that could not set itself up is the broker unavailable,
  // again with the slot released.
  let unset = broker_over(fake(observed, refusing: Some(dispatch.NotStarted)))
  let assert Error(broker.BrokerUnavailable) =
    broker.clear_call(unset, pooled, events:, waiting: 2000)
  let assert Error(broker.BrokerUnavailable) =
    broker.clear_call(unset, pooled, events:, waiting: 2000)
  broker.stop(unset)
}

pub fn execution_ids_name_their_incarnation_and_sequence_test() {
  let id = dispatch.execution_id(incarnation: 3, seq: 12)
  assert dispatch.incarnation(id) == 3
  assert dispatch.seq(id) == 12
  assert id != dispatch.execution_id(incarnation: 4, seq: 12)
  assert id == dispatch.execution_id(incarnation: 3, seq: 12)
}

/// Shared op/step can own multiple physical calls; seq is never the logical key.
pub fn successive_cleared_calls_keep_context_independent_of_sequence_test() {
  let observed = process.new_subject()
  let started = broker_over(fake(observed, refusing: None))
  let base = capped_spec(op(), 4)
  let events = process.new_subject()
  let names = [
    "job/j1",
    "turn-4-build",
    "hook:before-tool/fs_read",
    "00000000-0000-7000-8000-000000000001",
  ]

  // No path/label grammar is imposed on the broker's legitimate internal steps.
  list.each(names, fn(name) {
    let spec = broker.CallSpec(..base, step_id: name)
    let assert Ok(_) = broker.clear_call(started, spec, events:, waiting: 2000)
    let assert Started(request: first, guarantor: _) = next(observed)
    let assert Ok(_) = broker.clear_call(started, spec, events:, waiting: 2000)
    let assert Started(request: second, guarantor: _) = next(observed)
    assert first.context
      == dispatch.CallContext(operation: spec.op_id, step: name, origin: None)
    assert second.context == first.context
    assert second.seq == first.seq + 1
  })

  // A different durable operation survives the same broker instance as well.
  let assert Ok(other_operation) =
    ids.parse_op_id("00000000-0000-7000-8000-000000000002")
  let other_spec =
    broker.CallSpec(
      ..base,
      op_id: other_operation,
      step_id: "worktree-observation",
    )
  let assert Ok(_) =
    broker.clear_call(started, other_spec, events:, waiting: 2000)
  let assert Started(request: other, guarantor: _) = next(observed)
  assert other.context
    == dispatch.CallContext(
      operation: other_spec.op_id,
      step: other_spec.step_id,
      origin: None,
    )
  assert other.context.operation != base.op_id
  broker.stop(started)
}

/// Same-batch tools preserve distinct custody parents without splitting budgets.
pub fn durable_origins_survive_clearance_without_replacing_physical_context_test() {
  let observed = process.new_subject()
  let started = broker_over(fake(observed, refusing: None))
  let spec = capped_spec(op(), 4)
  let events = process.new_subject()
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 71)
  let #(session, generator) = ids.mint_session(generator)
  let #(entry_a, generator) = ids.mint_entry(generator)
  let #(entry_b, _) = ids.mint_entry(generator)
  let digest =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  let assert Ok(parent_a) =
    remote_tool.key(session, spec.op_id, spec.step_id, 0, digest, entry_a)
    as "the first durable parent must validate"
  let assert Ok(parent_b) =
    remote_tool.key(session, spec.op_id, spec.step_id, 1, digest, entry_b)
    as "the second durable parent must validate"
  let assert Ok(origin_a) =
    remote_tool.tool_child(parent_a, remote_tool.Compile)
    as "compile has a bounded child role"
  let assert Ok(origin_b) = remote_tool.tool_child(parent_b, remote_tool.Launch)
    as "launch has a bounded child role"

  // Provenance passes through clearance unchanged; physical phases retain their
  // own coordinates. The remote adapter validates the explicit relationship.
  let build_spec = broker.CallSpec(..spec, step_id: spec.step_id <> "-build")
  let assert Ok(_) =
    broker.clear_call_from(
      started,
      origin_a,
      build_spec,
      events:,
      waiting: 2000,
    )
    as "the derived build must clear"
  let assert Started(request: first, guarantor: _) = next(observed)
    as "the dispatcher must see the build"
  let assert Ok(_) =
    broker.clear_call_from(started, origin_b, spec, events:, waiting: 2000)
    as "the second tool must clear"
  let assert Started(request: second, guarantor: _) = next(observed)
    as "the dispatcher must see the launch"
  assert first.context.origin == Some(origin_a)
  assert second.context.origin == Some(origin_b)
  assert first.context.operation == spec.op_id
  assert first.context.step == build_spec.step_id
  assert second.context.step == spec.step_id
  assert first.context.origin != second.context.origin
  broker.stop(started)
}

/// Congestion may retry physical attempts but must retain the same durable child.
pub fn congestion_retries_keep_the_original_child_origin_test() {
  let observed = process.new_subject()
  let attempts = process.new_subject()
  let normal = fake(observed, refusing: None)
  let adapter =
    dispatch.Dispatcher(start: fn(request) {
      process.send(attempts, request.context)
      case request.seq {
        1 -> Error(dispatch.NoHelper(exec.AllBusy(size: 1)))
        _ -> normal.start(request)
      }
    })
  let started = broker_over(adapter)
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 79)
  let #(session, _) = ids.mint_session(generator)
  let assert Ok(origin) = remote_tool.system_child(session, "lsp", 19)
    as "the retained system invocation must validate"
  let events = process.new_subject()
  let spec = capped_spec(op(), 1)
  let assert Ok(_) =
    broker.clear_call_from(started, origin, spec, events:, waiting: 2000)
    as "the second physical attempt must clear"

  // The pooled slot is released on congestion, but provenance is not reminted.
  let assert Ok(first) = process.receive(attempts, 1000)
    as "the refused first attempt must be observed"
  let assert Ok(second) = process.receive(attempts, 1000)
    as "the successful retry must be observed"
  assert first == second
  assert second.origin == Some(origin)
  let assert Started(request:, guarantor: _) = next(observed)
    as "the retry must reach the dispatcher"
  assert request.seq == 2
  broker.stop(started)
}
