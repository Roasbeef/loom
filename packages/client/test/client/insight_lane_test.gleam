//// The lane and the rows of a finished session, rebuilt from its stored
//// entries alone. A turn whose tool call failed lifts one row under the
//// turn's own key; a peer message is never a candidate; and a candidate
//// names the piece that holds it.

import client/insight/lane
import gleam/list
import gleam/option.{None}
import session_view/attention
import session_view/turns
import support/insight_fixture

fn kinds(found: List(lane.Candidate)) -> List(attention.Kind) {
  list.map(found, fn(candidate) { candidate.row.kind })
}

pub fn each_failed_turn_lifts_one_row_newest_first_test() {
  let pieces = lane.pieces(insight_fixture.failed_turns(3, "boom"), ["main"])
  let found = lane.candidates(pieces)

  assert kinds(found)
    == [attention.FailedStep, attention.FailedStep, attention.FailedStep]

  // The newest turn is the last piece of the lane, so newest first means a
  // falling index.
  assert list.window_by_2(list.map(found, fn(candidate) { candidate.at }))
    |> list.all(fn(pair) { pair.0 > pair.1 })
}

pub fn a_candidate_names_the_work_piece_that_holds_its_row_test() {
  let pieces = lane.pieces(insight_fixture.failed_turns(2, "boom"), ["main"])

  list.each(lane.candidates(pieces), fn(candidate) {
    let assert Ok(held) = list.first(list.drop(pieces, candidate.at))
      as "the candidate's index is inside the lane"

    assert case held {
      turns.Work(key:, ..) -> key == candidate.row.key
      _ -> False
    }
  })
}

pub fn a_session_with_no_entries_has_no_lane_test() {
  assert lane.pieces([], []) == []
  assert lane.candidates([]) == []
}

pub fn a_peer_message_is_never_a_candidate_test() {
  let with_peer = [
    turns.Peer("1.0", "other", "main", "hello"),
    turns.Returned("2.0", "sub", "done", "the report", turns.Primary),
  ]

  assert kinds(lane.candidates(with_peer)) == [attention.SubagentResult("sub")]
}

pub fn a_pending_spawn_or_a_cache_note_lifts_nothing_test() {
  let quiet = [
    turns.Missed("1.0", "a cache miss"),
    turns.Spawned("2.0", None, "p", turns.Primary, turns.Pending, None),
  ]

  assert lane.candidates(quiet) == []
}
