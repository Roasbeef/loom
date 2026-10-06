//// A closed turn costs the page a summary, not its records.
////
//// The page keeps a settled turn as its prompt, its answer and one divider
//// whose figures were counted from every record of the turn, and reads the
//// turn's steps only when the reader opens the fold. These tests drive a page
//// whose gateway holds a whole session and hands it the newest hundred records
//// at first, as a real cut does, so the page has to read what it draws: the
//// start of a turn it opened inside, the turns below the oldest it holds, and
//// the newest steps of a fold.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/snapshot
import session_view/turns
import web_view/component
import web_view/view/lane

// The page of a reader who opened the session after it settled: the gateway's
// cut holds only the newest hundred records, and the page reads the rest.
fn reloaded(archive: List(snapshot.Item)) {
  opened_as(archive, "operator")
}

fn opened_as(archive: List(snapshot.Item), role: String) {
  let wire = process.new_subject()
  let capture = lane_fixture.newest(archive, 100)
  let #(page, _) =
    page_fixture.ready(wire, role)
    |> component.apply([capture])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.served(wire, archive, capture, role)
  #(page, wire, capture)
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

// The numbers of the folds the page draws, oldest turn first.
fn folds(page) -> List(Int) {
  list.filter_map(component.pieces(page), fn(piece) {
    case piece {
      turns.Work(id: Some(id), ..) -> Ok(id)
      turns.Work(id: None, ..)
      | turns.Plain(..)
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

// The steps each open fold holds and how many earlier ones it says it does not
// show.
fn drawn(page) -> List(#(Int, Int)) {
  list.filter_map(component.pieces(page), fn(piece) {
    case piece {
      turns.Work(items:, folding: turns.Unfolded(hidden:), ..) ->
        Ok(#(list.length(items), hidden))
      turns.Work(..)
      | turns.Plain(..)
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

fn pressed(page, wire, archive, capture) {
  page_fixture.run(page, component.update, [component.OlderRequested])
  |> lane_fixture.serve(wire, archive, capture)
}

// The sequence a history read asks below.
fn before_of(read: String) -> Int {
  let assert [_, rest] = string.split(read, "\"before_seq\":")
  let assert [digits, ..] = string.split(rest, "}")
  let assert Ok(before) = int.parse(digits)
  before
}

// Opens a fold and answers what the page asked for, and says which history
// reads it wrote.
fn opened(page, wire, archive, capture, fold: Int) {
  let page =
    page_fixture.run(page, component.update, [component.FoldToggled(fold)])
  let #(page, frames) =
    lane_fixture.served(page, wire, archive, capture, "operator")
  #(page, history_reads(frames))
}

fn history_reads(frames: List(String)) -> List(String) {
  list.filter(frames, fn(frame) {
    string.contains(frame, "\"cmd\":\"history\"")
  })
}

// A turn of 570 calls is over a thousand records, more than the window holds.
// Once it settles the page shows its prompt, its answer and a divider that
// counts every call, and does not offer to load what it already shows.
pub fn a_turn_of_570_steps_is_summarised_whole_test() {
  let #(page, _, _) = reloaded(lane_fixture.reading([570]))
  assert spoken(page) == ["question 1", "answer 1"]
  let assert [divider] = dividers(page)
  assert string.contains(divider, "570 steps")
  assert component.top(page) == lane.Beginning
}

// Turns before a long turn are reached by pages of turns, and the figures of
// each come from the turn and not from the rows the page happened to read.
pub fn the_turns_before_a_long_turn_are_reached_by_load_older_test() {
  let archive = lane_fixture.reading([3, 3, 570, 4])
  let #(page, wire, capture) = reloaded(archive)
  assert component.top(page) == lane.Earlier
  assert spoken(page) == ["question 3", "answer 3", "question 4", "answer 4"]
  let page = pressed(page, wire, archive, capture)
  assert spoken(page)
    == [
      "question 1",
      "answer 1",
      "question 2",
      "answer 2",
      "question 3",
      "answer 3",
      "question 4",
      "answer 4",
    ]
  assert component.top(page) == lane.Beginning
  let assert [_, _, long, _] = dividers(page)
  assert string.contains(long, "570 steps")
}

// Three turns of 110 calls are 666 records, over the window's bound, and the
// first of them is still on the page.
pub fn three_long_turns_are_all_reachable_test() {
  let archive = lane_fixture.reading([110, 110, 110])
  let #(page, wire, capture) = reloaded(archive)
  let page = pressed(page, wire, archive, capture)
  assert spoken(page)
    == [
      "question 1",
      "answer 1",
      "question 2",
      "answer 2",
      "question 3",
      "answer 3",
    ]
  assert list.length(dividers(page)) == 3
  assert component.top(page) == lane.Beginning
}

// A page that watched every turn arrive and a page that opened afterwards and
// read them draw the same figures.
pub fn a_reload_draws_the_divider_the_session_drew_test() {
  let archive = lane_fixture.reading([110, 110])
  let #(reloaded, wire, capture) = reloaded(archive)
  let reloaded = pressed(reloaded, wire, archive, capture)
  let whole =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.since(archive, 1, None)])
  assert dividers(reloaded) == dividers(whole)
  assert spoken(reloaded) == spoken(whole)
}

// A page that opens while a long turn runs draws what it holds of the turn, as
// it always has, and asks for nothing: the start of the turn is read only once
// the turn has settled and the page needs its figures.
pub fn a_running_turn_is_drawn_live_and_read_whole_once_it_settles_test() {
  let archive = lane_fixture.reading([570])
  let wire = process.new_subject()
  let midway = list.filter(archive, fn(item) { snapshot.sequence(item) <= 800 })
  let running = lane_fixture.since(midway, 701, Some(lane_fixture.op(1)))
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([running])
    |> page_fixture.run(component.update, [component.Ticked])
  assert history_reads(page_fixture.sent(wire)) == []
  assert component.rows(page) != []
  assert component.top(page) == lane.Earlier

  let settled = lane_fixture.newest(archive, 100)
  let page =
    component.apply(page, [settled])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.serve(wire, archive, settled)
  assert spoken(page) == ["question 1", "answer 1"]
  let assert [divider] = dividers(page)
  assert string.contains(divider, "570 steps")
}

// Feeds a page the captures of a session as it runs: each holds the newest
// hundred records so far, as a gateway's cut does, and the strand is running
// until the last.
fn watched(archive: List(snapshot.Item), every: Int) {
  let newest = list.length(archive)
  let marks =
    int.range(from: newest / every, to: 0, with: [], run: fn(all, n) {
      [n * every, ..all]
    })
  list.fold(
    list.append(marks, [newest]),
    component.new(page_fixture.start()),
    fn(page, upto) {
      let held =
        list.filter(archive, fn(item) { snapshot.sequence(item) <= upto })
      let operation = case upto == newest {
        True -> None
        False -> Some(lane_fixture.op(1))
      }
      component.apply(page, [
        lane_fixture.since(held, int.max(1, upto - 99), operation),
      ])
    },
  )
}

// A page that watched two long turns and a page opened after them draw the same
// dividers, figure for figure, and not merely the same number of them.
pub fn a_watched_page_and_a_reloaded_page_draw_equal_dividers_test() {
  let archive = lane_fixture.reading([110, 110])
  let #(reloaded, wire, capture) = reloaded(archive)
  let reloaded = pressed(reloaded, wire, archive, capture)
  let watched = watched(archive, 40)
  assert dividers(watched) == dividers(reloaded)
  assert folds(watched) == folds(reloaded)
}

// An input can land in a capture before its operation does. The prompt is then
// closed alone, and the rest of the turn arrives with no input of its own: the
// page reads the turn whole once it settles and draws one divider, the one a
// page opened afterwards draws.
pub fn an_input_before_its_operation_still_gives_one_divider_test() {
  let archive = lane_fixture.reading([110, 110])
  let wire = process.new_subject()
  let at = fn(upto: Int, operation) {
    let held =
      list.filter(archive, fn(item) { snapshot.sequence(item) <= upto })
    lane_fixture.since(held, int.max(1, upto - 99), operation)
  }
  let final = at(444, None)
  let page =
    list.fold(
      [
        at(40, Some(lane_fixture.op(1))),
        at(222, Some(lane_fixture.op(1))),
        at(222, None),
        at(223, None),
        at(263, Some(lane_fixture.op(2))),
        at(343, Some(lane_fixture.op(2))),
        at(423, Some(lane_fixture.op(2))),
        final,
      ],
      page_fixture.ready(wire, "operator"),
      fn(page, update) { component.apply(page, [update]) },
    )
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.serve(wire, archive, final)
  assert spoken(page) == ["question 1", "answer 1", "question 2", "answer 2"]
  let #(reloaded, wire, capture) = reloaded(archive)
  let reloaded = pressed(reloaded, wire, archive, capture)
  assert dividers(page) == dividers(reloaded)
  assert list.length(dividers(page)) == 2
}

// Two turns of 110 calls that arrive while the page watches are both drawn as
// closed dividers, with no press: a closed turn costs the page what a closed
// turn of two calls does, so the older is not behind "Load older".
pub fn two_long_turns_that_arrive_live_are_both_drawn_test() {
  let page = watched(lane_fixture.reading([110, 110]), 40)
  assert spoken(page) == ["question 1", "answer 1", "question 2", "answer 2"]
  assert component.top(page) == lane.Beginning
  assert list.length(dividers(page)) == 2
}

pub fn three_long_turns_that_arrive_live_are_all_drawn_test() {
  let page = watched(lane_fixture.reading([110, 110, 110]), 40)
  assert spoken(page)
    == [
      "question 1",
      "answer 1",
      "question 2",
      "answer 2",
      "question 3",
      "answer 3",
    ]
  assert component.top(page) == lane.Beginning
  assert list.all(dividers(page), fn(divider) {
    string.contains(divider, "110 steps")
  })
}

// Opening a fold of a closed turn reads that turn's newest steps and nothing
// else: a few intervals at the end of the turn, never the turns before it, and
// not the whole of the turn it opens.
pub fn opening_a_fold_reads_only_its_newest_steps_test() {
  let archive = lane_fixture.reading([3, 570])
  let #(page, wire, capture) = reloaded(archive)
  let page = pressed(page, wire, archive, capture)
  let assert [_, long] = folds(page)
  let #(open, reads) = opened(page, wire, archive, capture, long)

  // The turn is the records 9 to 1150, and its newest steps are at its end.
  assert reads != []
  assert list.length(reads) <= 3

  // A hundred rows of steps are the newest two hundred records, and the read
  // that stops at one of them has to go a little past them, since a result
  // whose call it did not reach is not drawn and does not count.
  assert list.all(reads, fn(read) { before_of(read) > 900 })
  let assert [#(held, hidden)] = drawn(open)
  assert held == 100

  // They are the newest steps of the turn: the first one drawn is far above the
  // steps that are hidden, which are the turn's first.
  let assert [turns.Work(items:, ..)] =
    list.filter(component.pieces(open), fn(piece) {
      case piece {
        turns.Work(folding: turns.Unfolded(_), ..) -> True
        _ -> False
      }
    })
  let assert Ok(turns.Step(key:, ..)) =
    list.find(items, fn(item) {
      case item {
        turns.Step(..) -> True
        _ -> False
      }
    })
  let assert [seq, _] = string.split(key, ".")
  let assert Ok(seq) = int.parse(seq)
  assert seq > hidden

  // The newest steps are the ones the read reached, and the earlier ones are
  // those it did not: a result whose call lay below the read is not drawn, so
  // the steps shown and not shown are the divider's 570 whichever way that
  // boundary fell.
  assert held + hidden == 570
  let html = element.to_string(component.view(open))
  assert string.contains(
    html,
    int.to_string(hidden)
      <> " earlier steps are not shown, to keep the page small.",
  )
}

// Until the steps arrive the divider is open and says it is reading, and the
// steps replace that line when they do.
pub fn a_fold_says_it_is_reading_until_its_steps_arrive_test() {
  let archive = lane_fixture.reading([570])
  let #(page, wire, capture) = reloaded(archive)
  let assert [fold] = folds(page)
  let waiting =
    page_fixture.run(page, component.update, [component.FoldToggled(fold)])
  let html = element.to_string(component.view(waiting))
  assert string.contains(html, "Reading the steps")
  assert string.contains(html, "aria-expanded=\"true\"")
  assert drawn(waiting) == []
  let arrived = lane_fixture.serve(waiting, wire, archive, capture)
  let html = element.to_string(component.view(arrived))
  assert !string.contains(html, "Reading the steps")
  assert drawn(arrived) != []
}

// Closing the fold drops its steps: the page holds a closed turn's summary and
// nothing else of it, and its rows are what they were.
pub fn closing_a_fold_drops_its_steps_test() {
  let archive = lane_fixture.reading([570])
  let #(page, wire, capture) = reloaded(archive)
  let rows = list.length(component.rows(page))
  let assert [fold] = folds(page)
  let #(open, _) = opened(page, wire, archive, capture, fold)
  assert list.length(component.rows(open)) > rows
  let closed =
    page_fixture.run(open, component.update, [component.FoldToggled(fold)])
  assert drawn(closed) == []
  assert list.length(component.rows(closed)) == rows
  let assert [turns.Plain(..), turns.Work(items: [], ..), turns.Plain(..)] =
    component.pieces(closed)
}

// The read is the page's own and takes only the number of a fold the page drew:
// a number that names no fold asks nothing, and a page that ended asks nothing.
pub fn a_fold_the_page_did_not_draw_reads_nothing_test() {
  let archive = lane_fixture.reading([3, 570])
  let #(page, wire, capture) = reloaded(archive)
  let page = pressed(page, wire, archive, capture)
  let before = component.pieces(page)
  let page =
    page_fixture.run(page, component.update, [
      component.FoldToggled(999_999),
      component.FoldToggled(-1),
      component.FoldToggled(9),
    ])
  assert page_fixture.sent(wire) == []
  assert component.pieces(page) == before

  let assert [_, long] = folds(page)
  let ended =
    page_fixture.run(page, component.update, [component.Refused("not open")])
  let ended =
    page_fixture.run(ended, component.update, [component.FoldToggled(long)])
  assert page_fixture.sent(wire) == []
  assert drawn(ended) == []
}

// An observer reads a fold through its own lane, as it reads older turns: the
// press asks for history and for nothing that is a command.
pub fn an_observer_reads_a_fold_with_reads_only_test() {
  let archive = lane_fixture.reading([570])
  let #(page, wire, capture) = opened_as(archive, "observer")
  let assert [fold] = folds(page)
  let page =
    page_fixture.run(page, component.update, [component.FoldToggled(fold)])
  let #(page, frames) =
    lane_fixture.served(page, wire, archive, capture, "observer")
  assert history_reads(frames) != []
  assert list.all(frames, fn(frame) {
    !string.contains(frame, "\"cmd\":\"prompt\"")
    && !string.contains(frame, "\"cmd\":\"steer\"")
    && !string.contains(frame, "\"cmd\":\"interrupt\"")
  })
  let assert [#(held, _)] = drawn(page)
  assert held == 100
}

// A read that is refused is given up and is not asked again until the reader
// presses again: the divider says how many steps it did not show.
pub fn a_refused_fold_read_is_not_repeated_test() {
  let archive = lane_fixture.reading([570])
  let #(page, wire, _) = reloaded(archive)
  let assert [fold] = folds(page)
  let page =
    page_fixture.run(page, component.update, [component.FoldToggled(fold)])
    |> page_fixture.refuse_reads(component.update, wire, component.Arrived)
  assert page_fixture.sent(wire) == []
  assert drawn(page) == [#(0, 570)]
  let page = page_fixture.run(page, component.update, [component.Ticked])
  assert page_fixture.sent(wire) == []
  assert drawn(page) == [#(0, 570)]
}

// A new page holds no open fold: the fold a page opened is the page's own
// state.
pub fn a_new_page_holds_no_open_fold_test() {
  let archive = lane_fixture.reading([570])
  let #(page, _, _) = reloaded(archive)
  assert drawn(page) == []
}

// Going Home and pressing the browser's Back opens the session's page again,
// which is a new page for the same session: it holds nothing of the page the
// reader left, so it draws what a first open draws, whatever the reader had
// loaded or opened there. The turns the reader loaded are one press away, the
// same press a first open offers.
pub fn a_page_that_back_returns_to_draws_what_a_first_open_draws_test() {
  let archive = lane_fixture.reading([30, 30, 30, 30])
  let #(first, wire, capture) = reloaded(archive)
  assert component.top(first) == lane.Earlier
  let loaded = pressed(first, wire, archive, capture)
  assert list.length(spoken(loaded)) > list.length(spoken(first))
  let assert [fold, ..] = folds(loaded)
  let #(open, _) = opened(loaded, wire, archive, capture, fold)
  assert drawn(open) != []

  let #(back, wire, capture) = reloaded(archive)
  assert spoken(back) == spoken(first)
  assert dividers(back) == dividers(first)
  assert drawn(back) == []
  assert component.top(back) == lane.Earlier
  let again = pressed(back, wire, archive, capture)
  assert spoken(again) == spoken(loaded)
}

// The steps each open fold of the page draws, oldest turn first.
fn open_items(page) -> List(turns.Item) {
  list.flat_map(component.pieces(page), fn(piece) {
    case piece {
      turns.Work(items:, folding: turns.Unfolded(_), ..) -> items
      turns.Work(..)
      | turns.Plain(..)
      | turns.Prompt(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..)
      | turns.Commentary(..) -> []
    }
  })
}

// A model that issues its calls in batches writes one message of many calls and
// then one record for each result. The newest hundred records of such a turn
// start among the results, so a read that stops there holds results whose call
// it did not reach. The fold draws no result without its call, and the steps it
// draws and the steps it says it does not show are the divider's count.
pub fn a_fold_over_batched_calls_draws_only_whole_steps_test() {
  let archive = lane_fixture.batched([[40, 40, 40]])
  let #(page, wire, capture) = reloaded(archive)
  let assert [divider] = dividers(page)
  assert string.contains(divider, "120 steps")
  let assert [fold] = folds(page)
  let #(open, _) = opened(page, wire, archive, capture, fold)
  let items = open_items(open)
  assert items != []
  assert list.all(items, fn(item) {
    case item {
      turns.Step(..) -> True
      turns.Narrated(..) | turns.Memory(..) -> False
    }
  })
  let assert [#(held, hidden)] = drawn(open)
  assert held == list.length(items)
  assert hidden > 0
  assert held + hidden == 120
  let html = element.to_string(component.view(open))
  assert string.contains(
    html,
    int.to_string(hidden)
      <> " earlier steps are not shown, to keep the page small.",
  )
}

// A refused read gives up on completing one lead. It does not outlive that
// lead: records that arrive afterwards with no input of their own are a lead
// of their own, and are read like the first, so the turn is one divider, as it
// is on a page opened after both.
pub fn a_refused_read_does_not_split_a_later_resume_test() {
  let first = lane_fixture.reading([110])
  let wire = process.new_subject()
  let page =
    page_fixture.ready(wire, "operator")
    |> component.apply([lane_fixture.newest(first, 100)])
    |> page_fixture.run(component.update, [component.Ticked])
    |> page_fixture.refuse_reads(component.update, wire, component.Arrived)
  assert list.length(dividers(page)) == 1

  let archive = lane_fixture.resumed(first, 3)
  let capture = lane_fixture.newest(archive, 100)
  let page =
    component.apply(page, [capture])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.serve(wire, archive, capture)
  let #(fresh, _, _) = reloaded(archive)
  assert list.length(dividers(page)) == 1
  assert dividers(page) == dividers(fresh)
}

// An aborted response draws one word, and the diagnostic the harness attached
// to a confirmed stop is not drawn: a reader who steered a turn is not shown the
// runtime's cause.
pub fn a_stopped_turn_says_stopped_and_not_why_test() {
  let aborted =
    lane_fixture.stopped(
      "provider request was cancelled (runtime: explicit stop)",
    )
  let page = component.apply(component.new(page_fixture.start()), [aborted])
  let assert [divider] = dividers(page)
  assert string.contains(divider, "interrupted")
  let assert [fold] = folds(page)
  let open =
    page_fixture.run(page, component.update, [component.FoldToggled(fold)])
  let html = element.to_string(component.view(open))
  assert string.contains(html, "Stopped")
  assert !string.contains(html, "explicit stop")
  assert !string.contains(html, "provider request was cancelled")
}

// Rows bound what the page draws and bytes bound what it holds: eight turns of
// one row each whose answers are 4 MB are over the budget for closed turns
// (`fold_budget.sealed_bytes`), so the page holds the newest and says there are
// older ones to load.
pub fn closed_turns_are_held_to_a_budget_of_bytes_test() {
  let page =
    component.new(page_fixture.start())
    |> component.apply([lane_fixture.heavy(8, 4_000_000)])
  assert list.length(spoken(page)) < 16
  assert list.length(spoken(page)) >= 2
  assert component.top(page) == lane.Earlier
}
