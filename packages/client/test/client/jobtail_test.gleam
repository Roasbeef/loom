//// The bounded job output tail: what a reader sees, what it is told it
//// missed, and where the window's two UTF-8 edges land.
////
//// Every test here is pure — no process, no clock, no store — which is
//// the point of the module being pure. The properties worth pinning are
//// the ones a reader of `client/jobs` will rely on without re-deriving:
//// the cursor never goes backwards, successive slices concatenate to the
//// stream when nothing was dropped, and a reader that fell behind is told
//// by how much rather than being handed a plausible-looking window.

import client/jobtail
import gleam/bit_array
import gleam/list

pub fn empty_tail_answers_with_nothing_test() {
  let tail = jobtail.new(capacity: 8)
  assert jobtail.received(tail) == 0
  assert jobtail.since(tail, 0)
    == jobtail.Since(bytes: <<>>, cursor: 0, dropped: 0)
}

pub fn a_chunk_inside_the_window_is_returned_whole_test() {
  let tail = jobtail.push(jobtail.new(capacity: 64), <<"hello":utf8>>)
  assert jobtail.since(tail, 0)
    == jobtail.Since(bytes: <<"hello":utf8>>, cursor: 5, dropped: 0)
}

pub fn a_cursor_at_the_end_sees_nothing_new_test() {
  let tail = jobtail.push(jobtail.new(capacity: 64), <<"hello":utf8>>)
  let seen = jobtail.since(tail, 0)
  assert jobtail.since(tail, seen.cursor)
    == jobtail.Since(bytes: <<>>, cursor: 5, dropped: 0)
}

pub fn successive_reads_concatenate_to_the_stream_test() {
  // Three chunks read one at a time: what the reader accumulates is the
  // stream, byte for byte, and the cursor only ever moves forward.
  let chunks = [<<"one ":utf8>>, <<"two ":utf8>>, <<"three":utf8>>]
  let #(_tail, cursor, seen) =
    list.fold(chunks, #(jobtail.new(capacity: 64), 0, <<>>), fn(carried, chunk) {
      let #(tail, cursor, seen) = carried
      let tail = jobtail.push(tail, chunk)
      let read = jobtail.since(tail, cursor)
      assert read.cursor >= cursor
      assert read.dropped == 0
      #(tail, read.cursor, bit_array.append(seen, read.bytes))
    })
  assert seen == <<"one two three":utf8>>
  assert cursor == 13
}

pub fn a_flood_past_the_capacity_stays_bounded_test() {
  // Sixteen kibibytes through a four-byte window: the window holds four
  // bytes and the reader is told the rest went past it.
  let tail =
    list.fold(list.repeat(Nil, 512), jobtail.new(capacity: 4), fn(tail, _step) {
      jobtail.push(tail, <<"0123456789abcdef0123456789abcdef":utf8>>)
    })
  assert jobtail.received(tail) == 16_384
  let read = jobtail.since(tail, 0)
  assert bit_array.byte_size(read.bytes) == 4
  assert read.cursor == 16_384
  assert read.dropped == 16_380
}

pub fn a_cursor_older_than_the_window_reports_the_gap_test() {
  // Ten bytes through a four-byte window. A reader still holding cursor
  // three missed bytes three, four and five; bytes six through nine are
  // still there.
  let tail = jobtail.push(jobtail.new(capacity: 4), <<"0123456789":utf8>>)
  assert jobtail.since(tail, 3)
    == jobtail.Since(bytes: <<"6789":utf8>>, cursor: 10, dropped: 3)
}

pub fn a_cursor_inside_the_window_reports_no_gap_test() {
  let tail = jobtail.push(jobtail.new(capacity: 4), <<"0123456789":utf8>>)
  assert jobtail.since(tail, 8)
    == jobtail.Since(bytes: <<"89":utf8>>, cursor: 10, dropped: 0)
}

pub fn a_cursor_outside_the_stream_is_clamped_test() {
  let tail = jobtail.push(jobtail.new(capacity: 64), <<"abc":utf8>>)

  // Ahead of the stream: nothing new, and the cursor comes back to the
  // end rather than staying in the future.
  assert jobtail.since(tail, 99)
    == jobtail.Since(bytes: <<>>, cursor: 3, dropped: 0)

  // Behind the beginning: the whole stream, and nothing was dropped
  // because nothing before byte zero ever existed.
  assert jobtail.since(tail, -5)
    == jobtail.Since(bytes: <<"abc":utf8>>, cursor: 3, dropped: 0)
}

pub fn a_split_character_is_held_back_until_it_completes_test() {
  // The pound sign is two bytes. A chunk that carries only the first of
  // them must not be handed over: the reader would decode a replacement
  // character for a character that arrived intact one chunk later.
  let whole = <<"£":utf8>>
  let assert Ok(head) = bit_array.slice(whole, 0, 1)
  let assert Ok(rest) = bit_array.slice(whole, 1, 1)

  let tail = jobtail.push(jobtail.new(capacity: 64), head)
  let first = jobtail.since(tail, 0)
  assert first == jobtail.Since(bytes: <<>>, cursor: 0, dropped: 0)

  let tail = jobtail.push(tail, rest)
  let second = jobtail.since(tail, first.cursor)
  assert second == jobtail.Since(bytes: whole, cursor: 2, dropped: 0)
}

pub fn the_window_front_lands_on_a_character_boundary_test() {
  // Three pound signs, six bytes, through a five-byte window. Cutting at
  // five would leave the window starting on a continuation byte, so the
  // trim walks one further forward and keeps four bytes rather than five.
  let tail = jobtail.push(jobtail.new(capacity: 5), <<"£££":utf8>>)
  let read = jobtail.since(tail, 0)
  assert read.bytes == <<"££":utf8>>
  assert read.dropped == 2
  assert bit_array.to_string(read.bytes) == Ok("££")
}

pub fn output_that_is_not_utf8_still_advances_the_cursor_test() {
  // A lone 0xFF is not the start of any character, so no amount of
  // waiting completes it. The bytes go out as they are rather than the
  // stream stalling at a boundary that is never coming.
  let tail = jobtail.push(jobtail.new(capacity: 64), <<0xFF, 0xFE, 0xFD>>)
  assert jobtail.since(tail, 0)
    == jobtail.Since(bytes: <<0xFF, 0xFE, 0xFD>>, cursor: 3, dropped: 0)
}

pub fn a_capacity_below_one_byte_is_raised_test() {
  // A silly capacity is a bound nobody meant, not a reason to fault a
  // job's output loop. One byte is the smallest window that can answer
  // anything at all.
  let tail = jobtail.push(jobtail.new(capacity: 0), <<"abc":utf8>>)
  let read = jobtail.since(tail, 0)
  assert read.bytes == <<"c":utf8>>
  assert read.dropped == 2
}
