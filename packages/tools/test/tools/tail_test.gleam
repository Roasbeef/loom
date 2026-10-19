//// Focused edge-case smoke checks for `tools/tail`; the full stateful
//// differential and UTF-8 window properties live in `tail_model_test.gleam`.

import gleam/bit_array
import tools/tail

pub fn empty_tail_and_clamped_capacity_smoke_test() {
  let empty = tail.new(capacity: 8)
  assert tail.received(empty) == 0
  assert tail.since(empty, 0) == tail.Since(bytes: <<>>, cursor: 0, dropped: 0)

  let tiny = tail.push(tail.new(capacity: 0), <<"abc":utf8>>)
  let read = tail.since(tiny, 0)
  assert read.bytes == <<"c":utf8>>
  assert read.dropped == 2
}

pub fn split_utf8_character_and_raw_binary_smoke_test() {
  let whole = <<"£":utf8>>
  let assert Ok(head) = bit_array.slice(whole, 0, 1)
  let assert Ok(rest) = bit_array.slice(whole, 1, 1)

  let held = tail.push(tail.new(capacity: 64), head)
  assert tail.since(held, 0) == tail.Since(bytes: <<>>, cursor: 0, dropped: 0)

  let completed = tail.push(held, rest)
  assert tail.since(completed, 0)
    == tail.Since(bytes: whole, cursor: 2, dropped: 0)

  let raw = tail.push(tail.new(capacity: 64), <<0xFF, 0xFE, 0xFD>>)
  assert tail.since(raw, 0)
    == tail.Since(bytes: <<0xFF, 0xFE, 0xFD>>, cursor: 3, dropped: 0)
}
