//// `cap/clock`: the clamp, and the fact that a sleep blocks one process
//// rather than the node.

import cap/clock
import gleam/erlang/process

/// A non-positive duration returns rather than failing, so a duration
/// computed as "the deadline minus now" needs no guard at the call site.
pub fn sleep_ms_clamps_a_non_positive_duration_test() {
  assert clock.sleep_ms(0) == Nil
  assert clock.sleep_ms(-1) == Nil
  assert clock.sleep_ms(-1_000_000) == Nil
}

/// A positive duration returns after waiting.
pub fn sleep_ms_returns_after_waiting_test() {
  assert clock.sleep_ms(1) == Nil
}

/// One process sleeping leaves the others running, which is the whole
/// reason an extension may poll with this: a worker waiting out its
/// interval must not stop the process that is watching for the answer.
pub fn a_sleep_blocks_one_process_only_test() {
  let done = process.new_subject()

  // The child sleeps first and reports second; the parent's receive is
  // what proves the parent was never held by the child's wait.
  process.spawn_unlinked(fn() {
    clock.sleep_ms(5)
    process.send(done, "woke")
  })

  assert process.receive(done, 5000) == Ok("woke")
}
