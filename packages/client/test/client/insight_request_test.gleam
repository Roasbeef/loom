//// The request the offline ordering test sends per session: eight rows at
//// most, two-piece windows, 600-byte blocks, an 8,192-byte request, the final
//// assistant message once, and never a line of reasoning.

import client/insight/lane
import client/insight/request
import client/notes
import gleam/int
import gleam/list
import gleam/string
import qcheck
import session_view/turns
import support/insight_fixture

// The fixed seed the generated sessions replay from.
const request_seed = 20_261_125

fn built(turns: Int, output: String) -> request.Request {
  let pieces =
    lane.pieces(insight_fixture.failed_turns(turns, output), ["main"])

  request.build(pieces, lane.candidates(pieces), request.standard)
}

pub fn rows_are_numbered_newest_first_and_capped_at_eight_test() {
  let pieces = lane.pieces(insight_fixture.failed_turns(12, "boom"), ["main"])
  let candidates = lane.candidates(pieces)
  let asked = request.build(pieces, candidates, request.standard)

  assert list.length(candidates) == 12
  assert asked.rows == list.take(candidates, 8)
  assert string.contains(asked.prompt, "Event 1 · ")
  assert string.contains(asked.prompt, "Event 8 · ")
  assert !string.contains(asked.prompt, "Event 9 · ")
}

pub fn every_event_names_its_kind_and_marks_its_own_piece_test() {
  let asked = built(3, "boom")

  assert string.contains(asked.prompt, "Event 1 · Failed · ")
  assert list.length(string.split(asked.prompt, "[this event]")) == 4
}

pub fn the_final_assistant_message_appears_once_and_reasoning_never_test() {
  let asked = built(3, "boom")

  assert list.length(string.split(
      asked.prompt,
      "turn 2 ended with the build failing",
    ))
    == 2
  assert !string.contains(asked.prompt, insight_fixture.secret_thought)
}

pub fn a_long_block_is_cut_from_the_middle_at_the_block_cap_test() {
  let held = [
    turns.Returned(
      "1.0",
      "sub",
      "done",
      string.repeat("r", 5000),
      turns.Primary,
    ),
  ]
  let asked = request.build(held, lane.candidates(held), request.standard)

  assert string.contains(asked.prompt, "bytes clipped")
  assert !string.contains(asked.prompt, string.repeat("r", 601))
}

pub fn a_tool_result_never_reaches_the_block_cap_unclipped_test() {
  let asked = built(2, string.repeat("a", 3000))

  assert !string.contains(asked.prompt, string.repeat("a", 601))
}

pub fn a_window_reaches_two_pieces_either_side_test() {
  let asked = built(5, "boom")

  // The oldest of five turns has no piece before it, and the pieces two
  // after it are the next turn's input and its work, so the fourth turn's
  // request is absent from it.
  let assert [_, ..] = asked.rows
  assert string.contains(asked.prompt, "turn 4: run the build")
  assert string.contains(asked.prompt, "turn 0: run the build")
}

pub fn every_row_keeps_its_own_piece_whatever_surrounds_it_test() {
  let asked = built(8, string.repeat("a", 3000))

  assert list.length(asked.rows) == 8
  assert list.length(string.split(asked.prompt, "[this event]")) == 9
  assert notes.byte_size(asked.prompt) <= request.standard.request_bytes
}

pub fn a_session_with_no_rows_asks_about_none_test() {
  assert request.build([], [], request.standard).rows == []
}

pub fn a_request_never_exceeds_its_cap_however_large_the_session_is_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(40)
    |> qcheck.with_seed(qcheck.seed(request_seed))
  let sessions =
    qcheck.tuple2(qcheck.bounded_int(0, 14), qcheck.bounded_int(0, 20_000))

  qcheck.run(config, sessions, fn(generated) {
    let #(turns, size) = generated
    let asked = built(turns, string.repeat("é", size))

    assert notes.byte_size(asked.prompt) <= request.standard.request_bytes
    assert list.length(asked.rows) <= request.standard.max_rows
    assert list.length(asked.rows) == int.min(turns, request.standard.max_rows)
  })
}
