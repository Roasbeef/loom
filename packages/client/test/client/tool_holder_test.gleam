//// The configuration holder answers with exactly what it was started over,
//// reports its own absence without crashing the asker, and retires on
//// request. The wiring tests cover the tool slot built on top of it.

import client/tool_holder

pub fn fetch_returns_the_held_configuration_test() {
  let assert Ok(holder) = tool_holder.start(["a", "b"])
    as "the holder must start"

  assert tool_holder.fetch(holder, within_ms: 1000) == Ok(["a", "b"])
  assert tool_holder.fetch(holder, within_ms: 1000) == Ok(["a", "b"])
  assert tool_holder.stop(holder) == Ok(Nil)
}

pub fn fetch_after_stop_reports_gone_test() {
  let assert Ok(holder) = tool_holder.start(1) as "the holder must start"
  assert tool_holder.stop(holder) == Ok(Nil)

  assert tool_holder.fetch(holder, within_ms: 1000) == Error(tool_holder.Gone)
}

pub fn stopping_a_stopped_holder_succeeds_test() {
  let assert Ok(holder) = tool_holder.start(1) as "the holder must start"

  assert tool_holder.stop(holder) == Ok(Nil)
  assert tool_holder.stop(holder) == Ok(Nil)
}
