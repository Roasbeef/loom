//// The engine's inbox holds what a host received in the order it was
//// received, and carries the host's source without looking at it.

import session_view/inbox

pub fn messages_are_taken_oldest_first_test() {
  let held =
    inbox.new("socket")
    |> inbox.push(1)
    |> inbox.push(2)
    |> inbox.push(3)
  assert inbox.held(held) == 3

  let #(held, first) = inbox.take(held)
  let #(held, second) = inbox.take(held)
  let #(held, third) = inbox.take(held)
  let #(held, none) = inbox.take(held)
  assert [first, second, third, none] == [Ok(1), Ok(2), Ok(3), Error(Nil)]
  assert inbox.held(held) == 0
}

pub fn the_source_survives_filing_and_taking_test() {
  let held = inbox.new("socket") |> inbox.push("frame")
  let #(taken, _) = inbox.take(held)
  assert inbox.source(held) == "socket"
  assert inbox.source(taken) == "socket"
}
