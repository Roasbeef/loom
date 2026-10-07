//// These controls use the real pool, executor and helper reducers with a synthetic
//// protocol peer. Native-port success is exercised separately after helper gates.
//// Census observations order tests; only the original returned proof is evidence.

import broker/exec
import broker/executor
import broker/framing
import broker/protocol_credit_test as peer
import broker/support/bench_host
import core/clock
import gleam/erlang/process
import gleam/otp/system
import telemetry/log
import weft/poll

fn fixture() {
  fixture_with([framing.protocol_credit_feature])
}

fn fixture_with(features: List(String)) {
  let #(helper, outbound) = peer.peer(features)
  let assert Ok(pool) = exec.start_pool(1, fn() { Ok(helper) })
    as "original synthetic pool starts"
  let assert Ok(native) =
    executor.start_registered_protocol_pool(pool, 19, log.discard())
    as "registered constructor retains the actual pool"
  #(helper, outbound, pool, native)
}

fn cleared(events: process.Subject(exec.ProtocolEvent)) {
  executor.ProtocolDispatch(
    3,
    peer.request(),
    clock.fixed(0),
    10_000,
    events,
    process.self(),
  )
}

fn started(
  native: executor.Executor,
  events: process.Subject(exec.ProtocolEvent),
) {
  let assert Ok(original) =
    executor.start_protocol(
      executor.dispatcher_collected_with_native_deadline(native),
      cleared(events),
    )
    as "registered actual reservation and Run succeed"
  original
}

fn completed(
  helper: exec.Helper,
  id: Int,
  events: process.Subject(exec.ProtocolEvent),
) {
  peer.terminal(helper, id, 0, 0)
  let assert Ok(exec.ProtocolTerminal(Ok(_), framing.ProtocolComplete)) =
    process.receive(events, 1000)
    as "exact native terminal remains distinct from checkin"
  peer.inbound(helper, framing.Frame(id, framing.ProtocolReusable(id)))
  let assert Ok(exec.ProtocolReusable) = process.receive(events, 1000)
    as "actual helper reducer offers its reusable witness"
  Nil
}

fn finish(
  helper: exec.Helper,
  outbound: process.Subject(BitArray),
  pool: exec.Pool,
  native: executor.Executor,
) {
  let closed = process.new_subject()
  process.spawn(fn() {
    process.send(closed, executor.close(native, draining: 0, helpers: 1000))
  })
  let _shutdown = peer.next(outbound)
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert process.receive(closed, 2000) == Ok(Ok(Nil))
  assert !process.is_alive(exec.pool_pid(pool))
}

pub fn synthetic_release_before_and_after_reusable_consumption_test() {
  let #(helper, outbound, pool, native) = fixture()
  let events = process.new_subject()
  let original = started(native, events)
  let first = peer.next(outbound)
  let returned = process.new_subject()
  executor.release_collected(original, returned)
  let _barrier = executor.census(native, waiting: 1000)
  assert process.receive(returned, 0) == Error(Nil)
  completed(helper, first.id, events)
  assert process.receive(returned, 0) == Error(Nil)
  executor.protocol_reusable_consumed(original)
  let assert Ok(Ok(proof)) = process.receive(returned, 1000)
    as "first original transition has actual proof"
  assert executor.verify_collected_return(original, proof) == Ok(Nil)

  // Returning the pool helper is independent of its next loan. Historical
  // evidence verifies while this exact helper is running a successor command.
  let next = started(native, events)
  let second = peer.next(outbound)
  assert second.id != first.id
  assert executor.verify_collected_return(original, proof) == Ok(Nil)
  assert executor.verify_collected_return(next, proof)
    == Error(exec.ReturnRefused)
  let duplicate = process.new_subject()
  executor.release_collected(original, duplicate)
  assert process.receive(duplicate, 1000) == Ok(Error(exec.ReturnRefused))
  executor.release_protocol_execution(original)
  executor.protocol_reusable_consumed(original)
  executor.cancel_protocol(original)
  let _barrier = executor.census(native, waiting: 1000)
  assert process.receive(outbound, 0) == Error(Nil)
  let assert exec.StatusBusy(_) = exec.status(helper, waiting: 1000)
    as "late original controls retain successor borrow"
  completed(helper, second.id, events)
  executor.protocol_reusable_consumed(next)
  let _barrier = executor.census(native, waiting: 1000)
  let after = process.new_subject()
  executor.release_collected(next, after)
  let assert Ok(Ok(second_proof)) = process.receive(after, 1000)
    as "release after consumption also proves the original transition"
  assert executor.verify_collected_return(next, second_proof) == Ok(Nil)
  assert process.receive(returned, 0) == Error(Nil)
  finish(helper, outbound, pool, native)
}

pub fn synthetic_pool_ack_held_preserves_native_row_and_original_observer_test() {
  let #(helper, outbound, pool, native) = fixture()
  let events = process.new_subject()
  let original = started(native, events)
  let first = peer.next(outbound)
  let returned = process.new_subject()
  executor.release_collected(original, returned)
  let _barrier = executor.census(native, waiting: 1000)
  completed(helper, first.id, events)

  // No assertions occur with either original actor suspended. Observations
  // are collected as Results, both actors resume, and only then are checked.
  system.suspend(exec.pid(helper))
  executor.protocol_reusable_consumed(original)
  let forwarded = executor.census(native, waiting: 1000)
  system.suspend(executor.pid(native))
  let successor = process.new_subject()
  let request = cleared(events)
  let dispatcher = executor.dispatcher_collected_with_native_deadline(native)
  process.spawn(fn() {
    process.send(successor, executor.start_protocol(dispatcher, request))
  })
  let queued =
    poll.until(1000, 1, fn() {
      case bench_host.queued(executor.pid(native)) > 0 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  system.resume(exec.pid(helper))
  let transitioned =
    poll.until(1000, 1, fn() {
      case exec.pool_census(pool, waiting: 1000) {
        Ok(exec.PoolCensus(available: 1, ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
  let held = process.receive(returned, 0)
  system.resume(executor.pid(native))
  let refused = process.receive(successor, 1000)
  let actual = process.receive(returned, 1000)
  assert forwarded != Error(executor.Unreachable)
  assert queued == poll.Answered(Nil)
  assert transitioned == poll.Answered(Nil)
  assert held == Error(Nil)
  let assert Ok(Error(executor.ProtocolNotStarted(_))) = refused
    as "same sequence is held until exact pool ACK is processed"
  let assert Ok(Ok(proof)) = actual
    as "the original observer receives the actual pool transition once"
  assert executor.verify_collected_return(original, proof) == Ok(Nil)
  let next = started(native, events)
  let second = peer.next(outbound)
  completed(helper, second.id, events)
  let done = process.new_subject()
  executor.release_collected(next, done)
  executor.protocol_reusable_consumed(next)
  let assert Ok(Ok(_)) = process.receive(done, 1000)
    as "the same helper remains usable after held ACK joins"
  finish(helper, outbound, pool, native)
}

pub fn synthetic_registered_refusal_retires_without_reusable_or_return_proof_test() {
  let #(helper, outbound, pool, native) =
    fixture_with([framing.protocol_credit_feature, "degraded"])
  let events = process.new_subject()
  let request = cleared(events)
  let request =
    executor.ProtocolDispatch(
      ..request,
      request: exec.ExecRequest(..request.request, demand: exec.FullEnforcement),
    )
  let answer =
    executor.start_protocol(
      executor.dispatcher_collected_with_native_deadline(native),
      request,
    )
  let assert Error(executor.ProtocolNotStarted(_)) = answer
    as "unsupported enforcement refuses after original return registration"
  let assert framing.Shutdown = peer.next(outbound).body
    as "refusal withdraws the original registered helper"
  assert process.receive(events, 0) == Error(Nil)
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert executor.close(native, draining: 0, helpers: 1000) == Ok(Nil)
}

pub fn synthetic_wrong_reservation_foreign_pool_and_duplicate_registration_refuse_test() {
  let #(helper, outbound) = peer.peer([framing.protocol_credit_feature])
  let #(foreign, foreign_outbound) =
    peer.peer([framing.protocol_credit_feature])
  let assert Ok(pool) = exec.start_pool(1, fn() { Ok(helper) })
    as "original pool starts"
  let assert Ok(other) = exec.start_pool(1, fn() { Ok(foreign) })
    as "foreign pool starts"
  let assert Ok(_) = exec.checkout(pool, waiting: 1000)
    as "original helper is borrowed"
  let assert Ok(_) = exec.checkout(other, waiting: 1000)
    as "foreign helper is borrowed"
  let assert Ok(original) = exec.reserve_protocol(helper, waiting: 1000)
    as "actual original reservation is retained"
  let completed = process.new_subject()
  let observer = fn(answer) { process.send(completed, answer) }
  assert exec.prepare_collected_return(other, original, observer)
    == Error(exec.ReturnRefused)
  let assert Ok(registered) =
    exec.prepare_collected_return(pool, original, observer)
    as "only exact pool can retain reservation"
  assert exec.prepare_collected_return(pool, original, observer)
    == Error(exec.ReturnRefused)
  assert exec.prepare_borrowed_retirement(pool, helper, fn(_) { Nil })
    == Error(exec.RetirementProofLost)
  assert process.receive(outbound, 0) == Error(Nil)
  exec.withdraw_collected(registered)
  let assert framing.Shutdown = peer.next(outbound).body
    as "exact original withdrawal uses existing retirement"
  assert exec.defer_collected_return(registered, waiting: 1000)
    == Error(exec.ProtocolViolation("deferred_checkin_identity"))
  assert process.receive(completed, 0) == Error(Nil)

  // Native exit and original normal DOWN remain the pool's separate cleanup.
  process.send(exec.wire(helper), exec.WireClosed(0))
  let assert Ok(Error(exec.ReturnRefused)) = process.receive(completed, 1000)
    as "retirement reports refusal rather than Available evidence"
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
  let closed = process.new_subject()
  process.spawn(fn() {
    process.send(closed, exec.close_pool(other, waiting: 1000))
  })
  let _shutdown = peer.next(foreign_outbound)
  process.send(exec.wire(foreign), exec.WireClosed(0))
  assert process.receive(closed, 2000) == Ok(Ok(Nil))
}

pub fn synthetic_lost_registration_reply_withdraws_original_proposal_without_run_test() {
  let #(helper, outbound) = peer.peer([framing.protocol_credit_feature])
  let assert Ok(pool) = exec.start_pool(1, fn() { Ok(helper) })
    as "original pool starts"
  let assert Ok(_) = exec.checkout(pool, waiting: 1000)
    as "original helper is borrowed"
  let assert Ok(reserved) = exec.reserve_protocol(helper, waiting: 1000)
    as "actual helper reservation precedes registration"
  let completed = process.new_subject()
  let answer = process.new_subject()
  system.suspend(exec.pool_pid(pool))
  process.spawn(fn() {
    process.send(
      answer,
      exec.prepare_collected_return(pool, reserved, fn(value) {
        process.send(completed, value)
      }),
    )
  })
  let queued =
    poll.until(1000, 1, fn() {
      case bench_host.queued(exec.pool_pid(pool)) > 0 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  let lost = process.receive(answer, 1500)
  system.resume(exec.pool_pid(pool))
  assert queued == poll.Answered(Nil)
  assert lost == Ok(Error(exec.ReturnUnknown))
  let assert framing.Shutdown = peer.next(outbound).body
    as "late original registration is withdrawn rather than dispatched or retried"
  assert process.receive(outbound, 0) == Error(Nil)
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert process.receive(completed, 1000) == Ok(Error(exec.ReturnRefused))
  assert process.receive(completed, 0) == Error(Nil)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

pub fn synthetic_legacy_checkin_cannot_bypass_registered_original_test() {
  let #(helper, outbound) = peer.peer([framing.protocol_credit_feature])
  let assert Ok(pool) = exec.start_pool(1, fn() { Ok(helper) })
    as "original pool starts"
  let assert Ok(_) = exec.checkout(pool, waiting: 1000)
    as "original helper is borrowed"
  let assert Ok(reserved) = exec.reserve_protocol(helper, waiting: 1000)
    as "actual helper reservation is retained"
  let completed = process.new_subject()
  let assert Ok(_) =
    exec.prepare_collected_return(pool, reserved, fn(value) {
      process.send(completed, value)
    })
    as "original observation precedes any Run"
  exec.checkin(pool, helper)
  let assert framing.Shutdown = peer.next(outbound).body
    as "legacy checkin withdraws observed borrow instead of making it lendable"
  assert process.receive(completed, 0) == Error(Nil)
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert process.receive(completed, 1000) == Ok(Error(exec.ReturnRefused))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

pub fn synthetic_reserved_original_and_legacy_run_composition_compatibility_test() {
  let #(helper, outbound) = peer.peer([framing.protocol_credit_feature])
  let events = process.new_subject()
  let assert Ok(old) =
    exec.run_protocol(
      helper,
      peer.request(),
      framing.FiniteCollected,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "legacy composition still performs reserve then Run"
  let first = peer.next(outbound)
  assert first.id == exec.protocol_execution_id(old)
  completed(helper, first.id, events)
  exec.protocol_reusable_consumed(old)
  let assert Ok(current) = exec.reserve_protocol(helper, waiting: 1000)
    as "new reservation is allocated after legacy consumption"
  assert exec.protocol_execution_id(current) != exec.protocol_execution_id(old)
  assert exec.run_reserved_protocol(
      old,
      peer.request(),
      framing.FiniteCollected,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    == Error(exec.ProtocolRunRefused(exec.NotReady))
  assert process.receive(outbound, 0) == Error(Nil)
  // The rejected old Run discards the mismatched proposal, as before. A new
  // reserved command still starts with its own immutable helper identity.
  let assert Ok(new) =
    exec.run_protocol(
      helper,
      peer.request(),
      framing.FiniteCollected,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "legacy behavior remains usable after an old reservation is refused"
  let second = peer.next(outbound)
  assert second.id == exec.protocol_execution_id(new)
  completed(helper, second.id, events)
  exec.protocol_reusable_consumed(new)
  exec.shutdown(helper)
  let _shutdown = peer.next(outbound)
  process.send(exec.wire(helper), exec.WireClosed(0))
}

pub fn synthetic_original_owner_death_keeps_observed_borrow_until_consumed_test() {
  let #(helper, outbound, pool, native) = fixture()
  let events = process.new_subject()
  let entered = process.new_subject()
  let answer = process.new_subject()
  let request = cleared(events)
  let dispatcher = executor.dispatcher_collected_with_native_deadline(native)
  process.spawn(fn() {
    let exit_owner = process.new_subject()
    let request = executor.ProtocolDispatch(..request, caller: process.self())
    process.send(answer, executor.start_protocol(dispatcher, request))
    process.send(entered, exit_owner)
    let _exit = process.receive(exit_owner, 1000)
    Nil
  })
  let assert Ok(Ok(original)) = process.receive(answer, 1000)
    as "original actual owner starts its registered command"
  let start = peer.next(outbound)
  let assert Ok(exit_owner) = process.receive(entered, 1000)
    as "owner retains original live context before death"
  process.send(exit_owner, Nil)
  let assert framing.Cancel = peer.next(outbound).body
    as "actual owner DOWN cancels the exact original command"
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  completed(helper, start.id, events)
  executor.protocol_reusable_consumed(original)
  let assert poll.Answered(Nil) =
    poll.until(1000, 1, fn() {
      case exec.pool_census(pool, waiting: 1000) {
        Ok(exec.PoolCensus(available: 1, ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "original owner loss does not bypass actual reusable consumption"
  finish(helper, outbound, pool, native)
}

pub fn synthetic_unknown_run_reply_retains_original_registration_test() {
  let #(helper, outbound, pool, native) = fixture()
  let events = process.new_subject()
  let reached = process.new_subject()
  let native_pid = executor.pid(native)
  let held =
    clock.from_function(fn() {
      case process.self() == native_pid {
        True -> 0
        False -> {
          let release = process.new_subject()
          process.send(reached, release)
          let _released = process.receive(release, 6000)
          0
        }
      }
    })
  let answer = process.new_subject()
  let request = executor.ProtocolDispatch(..cleared(events), clock: held)
  let dispatcher = executor.dispatcher_collected_with_native_deadline(native)
  process.spawn(fn() {
    process.send(answer, executor.start_protocol(dispatcher, request))
  })
  let reached = process.receive(reached, 1000)
  let unknown = process.receive(answer, 6000)
  case reached {
    Ok(release) -> process.send(release, Nil)
    Error(Nil) -> Nil
  }
  let assert Ok(Error(executor.ProtocolStartUnknown(
    original,
    exec.HelperUnresponsive,
  ))) = unknown
    as "actual Run reply timeout retains original native execution"
  let assert Ok(_) = reached as "actual helper clock owned its held reply"
  let start = peer.next(outbound)
  assert start.id == executor.protocol_execution_id(original)
  let assert framing.Cancel = peer.next(outbound).body
    as "uncertain original Run is cancelled through exact handle"
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  let returned = process.new_subject()
  executor.release_collected(original, returned)
  completed(helper, start.id, events)
  assert process.receive(returned, 0) == Error(Nil)
  executor.protocol_reusable_consumed(original)
  let assert Ok(Ok(proof)) = process.receive(returned, 1000)
    as "only actual consumed reusable can return this uncertain original"
  assert executor.verify_collected_return(original, proof) == Ok(Nil)
  finish(helper, outbound, pool, native)
}

pub fn synthetic_native_actor_loss_preserves_pool_registration_and_retirement_test() {
  let #(helper, outbound, pool, native) = fixture()
  let events = process.new_subject()
  let original = started(native, events)
  let start = peer.next(outbound)
  assert start.id == executor.protocol_execution_id(original)
  process.unlink(executor.pid(native))
  let monitor = process.monitor(executor.pid(native))
  process.kill(executor.pid(native))
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  let assert Ok(_) = down as "exact original executor death is observed"
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  // Original pool custody survives a dead callback receiver. Busy legacy
  // checkin withdraws this registration and cannot release its capacity.
  exec.checkin(pool, helper)
  let assert framing.Shutdown = peer.next(outbound).body
    as "pool independently retires the original observed native borrow"
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

pub fn synthetic_legacy_checkin_cannot_bypass_consumed_ready_registration_test() {
  let #(helper, outbound, pool, native) = fixture()
  let events = process.new_subject()
  let original = started(native, events)
  let start = peer.next(outbound)
  completed(helper, start.id, events)
  executor.protocol_reusable_consumed(original)
  let _forwarded = executor.census(native, waiting: 1000)
  let assert exec.StatusReady(_) = exec.status(helper, waiting: 1000)
    as "actual helper becomes Ready after consumption before deferred return"
  exec.checkin(pool, helper)
  let assert framing.Shutdown = peer.next(outbound).body
    as "Ready is insufficient to bypass the original observed return custody"
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert executor.close(native, draining: 0, helpers: 1000) == Ok(Nil)
}

pub fn synthetic_old_helper_reservation_cannot_register_successor_borrow_test() {
  let #(helper, outbound) = peer.peer([framing.protocol_credit_feature])
  let assert Ok(pool) = exec.start_pool(1, fn() { Ok(helper) })
    as "original pool starts"
  let assert Ok(_) = exec.checkout(pool, waiting: 1000)
    as "original helper is borrowed"
  let assert Ok(old) = exec.reserve_protocol(helper, waiting: 1000)
    as "actual original helper reservation exists"
  let returned = process.new_subject()
  let assert Ok(registered) =
    exec.prepare_collected_return(pool, old, fn(answer) {
      process.send(returned, answer)
    })
    as "original reservation is registered before Run"
  let events = process.new_subject()
  let assert Ok(_) =
    exec.run_reserved_protocol(
      old,
      peer.request(),
      framing.FiniteCollected,
      clock.fixed(0),
      10_000,
      events,
      waiting: 1000,
    )
    as "original registered reservation starts"
  let start = peer.next(outbound)
  completed(helper, start.id, events)
  assert exec.defer_collected_return(registered, waiting: 1000) == Ok(Nil)
  exec.protocol_reusable_consumed(old)
  let assert Ok(Ok(proof)) = process.receive(returned, 1000)
    as "actual original pool transition produces historical proof"
  assert exec.verify_collected_return(registered, proof) == Ok(Nil)
  let assert Ok(_) = exec.checkout(pool, waiting: 1000)
    as "the same helper has a distinct successor borrow"
  let assert Ok(_) = exec.reserve_protocol(helper, waiting: 1000)
    as "successor helper reservation has its own id"
  assert exec.prepare_collected_return(pool, old, fn(_) { Nil })
    == Error(exec.ReturnRefused)
  assert exec.defer_collected_return(registered, waiting: 1000)
    == Error(exec.ProtocolViolation("deferred_checkin_identity"))
  assert process.receive(outbound, 0) == Error(Nil)
  assert process.receive(returned, 0) == Error(Nil)
  let closed = process.new_subject()
  process.spawn(fn() {
    process.send(closed, exec.close_pool(pool, waiting: 1000))
  })
  let assert framing.Shutdown = peer.next(outbound).body
    as "original pool owns successor retirement separately"
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert process.receive(closed, 2000) == Ok(Ok(Nil))
}
