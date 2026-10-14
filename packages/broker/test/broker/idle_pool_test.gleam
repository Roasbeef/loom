//// Idle retirement runs on a manual timer source while helpers retain their
//// real protocol and custody handlers. Captured wakes can be delivered after
//// cancellation, exposing idle-generation races without a minute of sleep.

import broker/exec
import broker/framing
import broker/support/fake_helper
import gleam/erlang/process
import gleam/option.{None, Some}
import weft/poll
import weft/timer

type Arming {
  Arming(delay: Int, wake: fn() -> Nil)
}

fn timers(armings: process.Subject(Arming)) -> timer.Source {
  timer.Injected(after: fn(delay, wake) {
    process.send(armings, Arming(delay:, wake:))
  })
}

fn next_idle(armings: process.Subject(Arming)) -> fn() -> Nil {
  let assert Ok(Arming(delay, wake)) = process.receive(armings, 1000)
    as "successful checkin arms an idle deadline"
  assert delay == 60_000
  wake
}

fn census(pool: exec.Pool) -> exec.PoolCensus {
  let assert Ok(census) = exec.pool_census(pool, waiting: 1000)
    as "pool answers after preceding events"
  census
}

fn await_retired(pool: exec.Pool, count: Int) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case census(pool).retired == count {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "both retirement witnesses complete"
  Nil
}

pub fn idle_pool_drains_to_zero_and_replaces_lazily_test() {
  let armings = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool_with_timers(size: 2, timers: timers(armings), spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  let assert Ok(first) = exec.checkout(pool, waiting: 1000) as "first borrow"
  let assert Ok(second) = exec.checkout(pool, waiting: 1000) as "second borrow"
  assert process.receive(armings, 0) == Error(Nil)
  exec.checkin(pool, first)
  let first_idle = next_idle(armings)
  exec.checkin(pool, second)
  let second_idle = next_idle(armings)

  // Each available entry owns an independent timer, rather than a pool-wide
  // quiet period that another helper's use could perpetually postpone.
  first_idle()
  await_retired(pool, 1)
  assert census(pool).available == 1
  assert !process.is_alive(exec.pid(first))
  second_idle()
  await_retired(pool, 2)
  assert census(pool).available == 0
  assert census(pool).spawned == 2
  assert !process.is_alive(exec.pid(second))

  // Retirement frees capacity without pre-warming a new native process.
  let assert Ok(fresh) = exec.checkout(pool, waiting: 1000)
    as "lazy replacement"
  assert exec.pid(fresh) != exec.pid(first)
  assert census(pool).spawned == 3
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

pub fn idle_pool_cancelled_epoch_cannot_kill_a_borrowed_execution_test() {
  let armings = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool_with_timers(size: 1, timers: timers(armings), spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.SleepUntilCancel))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000) as "first borrow"
  exec.checkin(pool, helper)
  let old_idle = next_idle(armings)
  let assert Ok(reborrowed) = exec.checkout(pool, waiting: 1000) as "reborrow"
  assert exec.pid(reborrowed) == exec.pid(helper)
  let events = process.new_subject()
  let request =
    exec.ExecRequest(
      argv: ["sleep"],
      env: [],
      cwd: "/work",
      policy: None,
      token: <<0:size(32)-unit(8)>>,
      demand: exec.BestEffort,
    )
  assert exec.run(reborrowed, request, events:, waiting: 1000) == Ok(Nil)

  // An injected source cannot retract an already scheduled callback. Even
  // repeated delivery must leave a borrowed, potentially unbounded run alone.
  old_idle()
  old_idle()
  assert census(pool).borrowed == 1
  let assert exec.StatusBusy(_) = exec.status(helper, waiting: 1000)
    as "borrowed execution survives idle wake"
  assert process.receive(events, 0) == Error(Nil)
  exec.cancel(reborrowed)
  let assert Ok(exec.Exited(_)) = process.receive(events, 1000)
    as "explicit cancellation settles the run"
  exec.checkin(pool, reborrowed)
  let new_idle = next_idle(armings)

  // The next available interval receives the entire fixed period. A wake
  // from the first interval is stale even though the entry is available again.
  old_idle()
  assert census(pool).available == 1
  assert census(pool).retired == 0
  new_idle()
  await_retired(pool, 1)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

pub fn idle_pool_queries_and_duplicate_checkin_do_not_refresh_test() {
  let armings = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool_with_timers(size: 1, timers: timers(armings), spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000) as "borrow"
  exec.checkin(pool, helper)
  let wake = next_idle(armings)
  exec.checkin(pool, helper)
  assert census(pool).available == 1
  let assert Ok(view) = exec.pool_custody(pool, waiting: 1000)
    as "custody query answers"
  assert view.census.available == 1
  assert process.receive(armings, 0) == Error(Nil)
  wake()
  await_retired(pool, 1)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

// The test owns the channel and supplies native exit separately from the
// shutdown write, so requesting retirement cannot masquerade as its proof.
fn controlled(sent: process.Subject(BitArray)) -> exec.Helper {
  let config =
    exec.default_config(
      exec.ChannelTransport(
        send: fn(bytes) { process.send(sent, bytes) },
        close: fn() { Nil },
      ),
    )
  let assert Ok(helper) =
    exec.start(exec.HelperConfig(..config, heartbeat_interval_ms: 0))
    as "controlled helper starts"
  let assert Ok(hello) =
    framing.encode(framing.Frame(
      id: 1,
      body: framing.Hello(
        proto: framing.exec_protocol_version,
        peer: "exec-helper",
        features: [],
        max_concurrency: Some(1),
      ),
    ))
    as "hello encodes"
  process.send(exec.wire(helper), exec.WireBytes(hello))
  assert exec.await_ready(helper, waiting: 1000) == Ok([])
  helper
}

fn shutdown_written(sent: process.Subject(BitArray)) -> Nil {
  let assert Ok(bytes) = process.receive(sent, 1000) as "shutdown written"
  let assert framing.Pushed(
    inbound: [framing.Known(framing.Frame(body: framing.Shutdown, ..))],
    fault: None,
    ..,
  ) = framing.push(framing.deframer(), bytes)
    as "one shutdown frame"
  Nil
}

pub fn idle_pool_keeps_capacity_until_retirement_is_witnessed_test() {
  let armings = process.new_subject()
  let sent = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool_with_timers(size: 1, timers: timers(armings), spawn: fn() {
      Ok(controlled(sent))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000) as "borrow"
  let assert Ok(_) = process.receive(sent, 1000) as "broker hello written"
  exec.checkin(pool, helper)
  let wake = next_idle(armings)
  wake()
  shutdown_written(sent)
  assert census(pool).draining == 1
  assert census(pool).retired == 0
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(size: 1))
  assert process.is_alive(exec.pid(helper))

  // Only the clean native status permits the owner to exit, and only its
  // normal monitor event removes the inventory entry and frees capacity.
  process.send(exec.wire(helper), exec.WireClosed(0))
  await_retired(pool, 1)
  assert !process.is_alive(exec.pid(helper))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

pub fn idle_pool_failed_retirement_keeps_custody_and_capacity_test() {
  let armings = process.new_subject()
  let sent = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool_with_timers(size: 1, timers: timers(armings), spawn: fn() {
      Ok(controlled(sent))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000) as "borrow"
  let assert Ok(_) = process.receive(sent, 1000) as "broker hello written"
  exec.checkin(pool, helper)
  let wake = next_idle(armings)
  wake()
  shutdown_written(sent)
  process.send(exec.wire(helper), exec.WireClosed(137))
  let assert poll.Answered(Nil) =
    poll.until(within: 1000, every: 1, attempt: fn() {
      case census(pool).unconfirmed == 1 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "failure remains inventoried"
  assert census(pool).retired == 0
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(size: 0))
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementExit(137))
}

pub fn idle_pool_close_cancels_wakes_without_double_shutdown_test() {
  let armings = process.new_subject()
  let sent = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool_with_timers(size: 1, timers: timers(armings), spawn: fn() {
      Ok(controlled(sent))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000) as "borrow"
  let assert Ok(_) = process.receive(sent, 1000) as "broker hello written"
  exec.checkin(pool, helper)
  let wake = next_idle(armings)
  assert exec.close_pool(pool, waiting: 1) == Error(exec.RetirementPending)
  shutdown_written(sent)
  wake()
  exec.checkin(pool, helper)
  assert census(pool).draining == 1
  assert process.receive(sent, 0) == Error(Nil)
  assert process.receive(armings, 0) == Error(Nil)
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
  wake()
}

// Each pool owns its own timer book. A busy neighbour cannot keep a quiet
// session's native inventory alive.
pub fn idle_pool_deadlines_are_independent_across_pools_test() {
  let first_armings = process.new_subject()
  let second_armings = process.new_subject()
  let spawn = fn() { Ok(fake_helper.start_helper(fake_helper.EchoArgv)) }
  let assert Ok(quiet) =
    exec.start_pool_with_timers(size: 1, spawn:, timers: timers(first_armings))
    as "quiet pool starts"
  let assert Ok(active) =
    exec.start_pool_with_timers(size: 1, spawn:, timers: timers(second_armings))
    as "active pool starts"
  let assert Ok(first) = exec.checkout(quiet, waiting: 1000) as "quiet borrow"
  exec.checkin(quiet, first)
  let quiet_wake = next_idle(first_armings)
  let assert Ok(second) = exec.checkout(active, waiting: 1000)
    as "active borrow"
  exec.checkin(active, second)
  let active_wake = next_idle(second_armings)
  let assert Ok(again) = exec.checkout(active, waiting: 1000)
    as "active reborrow"
  assert exec.pid(again) == exec.pid(second)
  active_wake()
  quiet_wake()
  await_retired(quiet, 1)
  assert census(active).borrowed == 1
  assert exec.close_pool(quiet, waiting: 1000) == Ok(Nil)
  assert exec.close_pool(active, waiting: 1000) == Ok(Nil)
}
