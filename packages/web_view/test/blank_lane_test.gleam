//// A fresh open of a session draws the newest turn, whichever strand wrote last.
////
//// A gateway's cut is the newest fifty records of the whole session. The advisor
//// reviews a turn after it settles, and the review's records take the newest
//// sequences, so when it is long the cut holds none of `main`'s records: its leaf
//// is below the cut. The page used to read that as a strand with nothing in it,
//// and drew "Beginning of this conversation." over an empty lane. These tests
//// open such a session as a reader does, with a gateway that holds the whole of
//// it, and expect the newest turn's prompt, its divider with the turn's step
//// count and its answer, and the offer of older turns when there are any.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import lane_fixture
import page_fixture
import session_view/snapshot
import session_view/turns
import web_view/component
import web_view/view/lane

// The records of `turns` (the batches of each turn's parallel calls) and then a
// review of `review` records by the advisor, and the cut a gateway sends of
// them.
fn reviewed(turns: List(List(Int)), review: Int) {
  let main = lane_fixture.batched(turns)
  let archive = lane_fixture.advised(main, review)
  let capture =
    lane_fixture.newest_by(archive, 50, [
      #("main", list.length(main)),
      #("advisor", list.length(archive)),
    ])
  #(archive, capture)
}

// The page a reader gets on opening the session, once the page has read what it
// wanted of it.
fn opened(archive: List(snapshot.Item), capture) {
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([capture])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.serve(wire, archive, capture)
  #(page, wire)
}

// The first line of each piece the page draws that is a person's words or an
// answer, oldest first.
fn spoken(page) -> List(String) {
  list.filter_map(component.pieces(page), fn(piece) {
    case piece {
      turns.Plain(block:, ..) | turns.Prompt(block:, ..) ->
        case block.rows {
          [#(_, line), ..] -> Ok(line.text)
          [] -> Error(Nil)
        }
      turns.Work(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..)
      | turns.Commentary(..) -> Error(Nil)
    }
  })
}

// What each divider the page draws says: its figures.
fn dividers(page) -> List(String) {
  list.filter_map(component.pieces(page), fn(piece) {
    case piece {
      turns.Work(worked:, folding:, ..) ->
        case folding {
          turns.Open -> Error(Nil)
          turns.Folded | turns.Reading | turns.Unfolded(_) ->
            Ok(turns.divider(worked))
        }
      turns.Plain(..)
      | turns.Prompt(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..)
      | turns.Commentary(..) -> Error(Nil)
    }
  })
}

// The history reads the page has written and not had answered.
fn reads(wire) -> List(String) {
  list.filter(page_fixture.sent(wire), fn(frame) {
    string.contains(frame, "\"cmd\":\"history\"")
  })
}

// One turn of these parallel calls, opened after a review of this many records.
// A review of fifty or more takes the whole cut; a short one leaves the end of
// `main` in it, and those pages were always drawn.
fn draws_whole(batches: List(Int), review: Int) -> Nil {
  let steps = list.fold(batches, 0, int.add)
  let #(archive, capture) = reviewed([batches], review)
  let #(page, _) = opened(archive, capture)
  assert spoken(page) == ["question 1", "answer 1"]
  let assert [divider] = dividers(page)
  assert string.contains(divider, int.to_string(steps) <> " step")
  assert component.top(page) == lane.Beginning
}

// The shapes of parallel calls the blank pages were found with, and the ones
// that were always drawn, behind a long review and a short one.
pub fn the_newest_turn_is_drawn_whatever_the_advisor_wrote_after_it_test() {
  list.each(
    [
      [1],
      [8, 8, 8, 8],
      [22, 22],
      [40],
      [55],
      [90],
      [25, 25],
      [40, 40, 40],
      [31, 31, 31, 31, 31],
    ],
    fn(batches) {
      draws_whole(batches, 60)
      draws_whole(batches, 5)
    },
  )
}

// With older turns below, the newest is still drawn, Load older is offered, and
// pressing it brings the turn below.
pub fn older_turns_are_offered_below_the_newest_test() {
  let #(archive, capture) = reviewed([[90], [55]], 60)
  let #(page, wire) = opened(archive, capture)
  assert spoken(page) == ["question 2", "answer 2"]
  assert component.top(page) == lane.Earlier
  let page =
    page_fixture.run(page, component.update, [component.OlderRequested])
    |> lane_fixture.serve(wire, archive, capture)
  assert spoken(page) == ["question 1", "answer 1", "question 2", "answer 2"]
  assert component.top(page) == lane.Beginning
}

// The page reads the turn from the strand's leaf in the bounded intervals every
// read uses, and while it does the lane says it is loading and not that the
// conversation begins.
pub fn the_page_says_it_is_loading_until_the_turn_arrives_test() {
  let #(archive, capture) = reviewed([[55]], 60)
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([capture])
    |> page_fixture.run(component.update, [component.Ticked])
  assert component.top(page) == lane.Loading
  assert spoken(page) == []
  let page = lane_fixture.serve(page, wire, archive, capture)
  assert component.top(page) == lane.Beginning
}

// The advisor's strand receives one kind of message, the feed of what the
// primary did, and answers each in a run of its own. A feed starts a turn as a
// person's message does, so the page completes the newest review by reading back
// to its feed. When a feed started nothing, the strand was one turn with no
// start, and its first open read the strand's whole history, a hundred
// sequences at a time and one read after the other, with the lane saying it was
// loading throughout.
pub fn a_strand_that_only_receives_feeds_opens_in_a_few_reads_test() {
  let archive = lane_fixture.reviews(1500)
  let capture =
    lane_fixture.newest_by(archive, 50, [
      #("main", 2),
      #("advisor", list.length(archive)),
    ])
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([capture])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.serve(wire, archive, capture)
  let #(page, frames) =
    page_fixture.run(page, component.update, [
      component.FocusRequested("advisor"),
    ])
    |> lane_fixture.served(wire, archive, capture, "operator")
  assert list.length(
      list.filter(frames, fn(frame) {
        string.contains(frame, "\"cmd\":\"history\"")
      }),
    )
    <= 3
  assert component.top(page) != lane.Loading
  assert component.pieces(page) != []
}

// The number of history reads among `frames`, and the lowest sequence any of
// them asked below.
fn read_cost(frames: List(String)) -> #(Int, Int) {
  let asked =
    list.filter_map(frames, fn(frame) {
      case string.split(frame, "\"before_seq\":") {
        [_, rest] ->
          case string.contains(frame, "\"cmd\":\"history\"") {
            True ->
              case string.split(rest, "}") {
                [digits, ..] -> int.parse(digits)
                [] -> Error(Nil)
              }
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  #(list.length(asked), list.fold(asked, 1_000_000, int.min))
}

// A strand sparse among the session's sequences is read in steps. Its leaf is
// below five thousand records another strand wrote, and every interval of a
// hundred sequences holds none of its own, so a read that went on until it found
// one would be fifty reads. The page reads at most eight intervals that find
// nothing, says so by offering Load older, and each press goes on below where the
// last stopped until the turn is found.
pub fn a_sparse_strand_is_read_in_steps_test() {
  let main = lane_fixture.batched([[2]])
  let archive = lane_fixture.advised(main, 5000)
  let capture =
    lane_fixture.newest_by(archive, 50, [
      #("main", list.length(main)),
      #("advisor", list.length(archive)),
    ])
  let wire = process.new_subject()
  let #(page, frames) =
    page_fixture.ready(wire, "operator")
    |> component.apply([capture])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.served(wire, archive, capture, "operator")
  let #(reads, lowest) = read_cost(frames)
  assert reads <= 8
  assert spoken(page) == []
  assert component.top(page) == lane.Earlier
  press_until_drawn(page, wire, archive, capture, lowest, 0)
}

fn press_until_drawn(page, wire, archive, capture, lowest: Int, presses: Int) {
  case spoken(page) {
    [] -> {
      assert presses < 10
      let #(page, frames) =
        page_fixture.run(page, component.update, [component.OlderRequested])
        |> lane_fixture.served(wire, archive, capture, "operator")
      let #(reads, next) = read_cost(frames)
      assert reads <= 8
      assert next < lowest
      press_until_drawn(page, wire, archive, capture, next, presses + 1)
    }
    drawn -> {
      assert presses >= 2
      assert drawn == ["question 1", "answer 1"]
    }
  }
}

// A refused read is not asked again by the page: it offers Load older, the
// reader's press tries again, and the turn is drawn when that is answered.
pub fn a_refused_read_is_left_to_the_reader_test() {
  let #(archive, capture) = reviewed([[55]], 60)
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([capture])
    |> page_fixture.run(component.update, [component.Ticked])
    |> page_fixture.refuse_reads(component.update, wire, component.Arrived)
    |> page_fixture.run(component.update, [component.Ticked])
  assert reads(wire) == []
  assert component.top(page) == lane.Earlier
  assert spoken(page) == []
  let page =
    page_fixture.run(page, component.update, [component.OlderRequested])
    |> lane_fixture.serve(wire, archive, capture)
  assert spoken(page) == ["question 1", "answer 1"]
}
