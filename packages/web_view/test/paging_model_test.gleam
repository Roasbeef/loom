//// Model-based test of the web view's paging and turn sealing.
////
//// `paging_test`, `turn_summary_test`, `lazy_fold_test` and `browsing_test`
//// pin the page with worked examples. This module adds the other half: a
//// generated sequence of the events a page meets (the session appending
//// turns, a turn running, settling and going on after it settled, the reader
//// pressing "Load older", "Jump to latest" or a divider, the gateway answering
//// or refusing the page's reads, a tick of the lane's timer), run against the
//// real `component` through the frames it writes, with the page's promises
//// checked after every event. `statem` generates and shrinks the sequences,
//// so a failure is reported as the few events that break a promise.
////
//// ## What is checked, and where it is stated
////
//// Each promise has its own `Violation` tag, because shrinking keeps a
//// failure to the tag it started with and two bugs must not trade places.
////
//// - `paging.rows` is the bound on what the page draws.
////   `component.live_rows` (`component.gleam`, line 272) says the page holds
////   the newest rows of the strand up to 150, and `component.held_rows` (line
////   286) that a paged page holds twice that. The folds a reader opens have a
////   reserve of their own, `fold_budget.fold_rows` (`fold_budget.gleam`, line
////   144), so "what a page draws is bounded by its limit plus that constant";
////   the reserve is only for a closed turn's open fold, so the bound is the
////   limit itself until the reader has one open. The package's CLAUDE.md
////   ("The page's rows are bounded") adds the one case outside it, a running
////   turn longer than the limit, which this history cannot make because a
////   capture carries at most a hundred records.
//// - `paging.one_read` is "one read at a time": the lane has one request out
////   at a time (`paging_test`, the press test; CLAUDE.md, "One read at a
////   time"). The ledger of what the page has written and the test has not
////   answered never holds two requests.
//// - `paging.loading` is `component.older` (line 6158): "While it is out the
////   lane draws `lane.Loading`". A press on a page the lane offers older rows
////   for is owed its rows, and the lane says it is loading until the page's
////   reads are answered, however the paging state moves meanwhile.
//// - `paging.full` is the doc of `component.Paging` (line 853 and the
////   variants above it): on a `Full` or `Crowded` page the next older press
////   enters `Browsing`. A press on a page that cannot grow does not grow it.
//// - `paging.moves` is the direction of the paging state. `component.paged`
////   leaves a full page full, `Crowded` is left only by the running turn
////   settling, and `Browsing` is left only by `latest_at`, which "adopts the
////   live tail again"; `Tail` is left only by a press. So `Tail` returns only
////   through "Jump to latest", `Full` and `Browsing` never turn back into
////   `Paged`, and `Full` becomes `Browsing` only by a press.
//// - `paging.divider` is the promise at the head of `turn_ledger` (line 27):
////   "A page that watched the turn and a page opened after it therefore draw
////   the same divider once the turn settles". It is checked in `finish`: the
////   session is settled, the live page is given every read it asked for, a
////   second page is built fresh from the same history, and every divider the
////   two both draw must be the same `Worked`. `Resume` is the history that
////   makes it bite: a turn that goes on after it settled, with no input of its
////   own, which the watching page sealed once and must seal again.
////
//// ## The page is driven through its frames
////
//// There is no runtime here. `component.update` is a pure reduction whose
//// effects `page_fixture.run` performs against a subject the test owns, so
//// every frame the page transmits can be read and answered. The history is
//// the fixture's `lane_fixture.reading` conversation, which
//// `lane_fixture.served` answers as a gateway would, and each capture is the
//// newest hundred records of it, as a gateway cuts them. A reply is only ever
//// the daemon's honest answer to the read the page sent; the events that
//// shape the page are the ones the reader and the session can cause. A lane
//// failure is not a command: it ends the page, and nothing after it would
//// test paging.
////
//// ## Commands
////
//// The model is the history the session has produced: the steps of each
//// settled turn, of the running one, and of a turn that resumed. Every
//// command is admissible while the history can grow, and a command that
//// names nothing (`Refuse` with no read out, `Fold` with no divider) does
//// nothing, so shrinking can delete earlier commands freely. The fixture can
//// continue a conversation's sequence only once, so a resume ends the history
//// and the precondition rejects growth after it. The generator reads only the
//// model, never the page, and asks for a long history first, since a page
//// with nothing older to read tests nothing.
////
//// `statem.commands` is replayed by a second test, which fails if the
//// generator stops reaching a state the promises are about: every paging
//// state, a read left out, a fold the reader opened, a final comparison with
//// dividers to compare, and one after a resume.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lane_fixture
import page_fixture
import qcheck
import session_view/fold_budget
import session_view/snapshot
import session_view/turns
import statem.{type Spec, type Violation, Admit, Reject, Spec, Violation}
import web_view/component
import web_view/view/lane

// --- configuration -----------------------------------------------------------

/// Fixed so a red gate is the same red gate on every machine; changing it
/// re-draws every sequence.
const seed = 20_261_018

/// How many generated sequences the property runs. Each executes a page over
/// histories of hundreds of records, so the count is what the budget buys.
const test_count = 40

/// The longest sequence. Greedy shrinking is quadratic in this; twelve events
/// is enough to build a long history, open a read, answer it, and settle.
const max_commands = 20

/// How many of those sequences the reach census walks. It executes each one,
/// so it costs what the property costs per run; the first twenty meet every
/// state it asks for.
const census_runs = 20

// --- the model ---------------------------------------------------------------

/// The history the session has produced, in turns of `reading`'s shape: a
/// turn of `n` steps is a question, `n` calls with their results, and an
/// answer.
type Model {
  Model(
    /// The step counts of the settled turns, oldest first.
    settled: List(Int),
    /// The step count of the running turn, whose answer is not yet written.
    running: Option(Int),
    /// The steps the newest turn went on to take after it settled, with no
    /// input of its own. Nothing can follow it: the fixture continues the
    /// conversation's sequence once.
    resumed: Option(Int),
  )
}

/// One event the page meets.
type Cmd {
  /// The session settles any running turn and writes `turns` more settled
  /// turns of `steps` steps each, and the page receives a capture.
  Append(turns: Int, steps: Int)

  /// The session settles any running turn and begins another of `steps`
  /// steps, whose answer is not yet written, and the page receives a capture.
  Open(steps: Int)

  /// The running turn's answer is written, if one runs, and the page receives
  /// the capture of the strand now idle.
  Settle

  /// The newest turn goes on after it settled with `steps` more calls and a
  /// new answer, and no new input (a provider retry, a restart), as the
  /// `turn_ledger` doc describes. It ends the history: nothing is appended
  /// after it.
  Resume(steps: Int)

  /// The reader presses "Load older".
  Press

  /// The reader presses "Load older" and the gateway answers every read that
  /// asks, so one event moves the page a whole press deeper.
  Read

  /// The reader presses the divider of the closed turn at `index`, modulo
  /// the dividers the page draws: an open fold closes, a closed one opens
  /// and its steps are read.
  Fold(index: Int)

  /// The reader presses "Jump to latest".
  Latest

  /// The lane's timer fires.
  Tick

  /// The gateway answers every read the page has out, and those the answers
  /// free, from the session's history.
  Serve

  /// The gateway refuses the oldest history read the page has out.
  Refuse
}

fn describe(cmd: Cmd) -> String {
  string.inspect(cmd)
}

// The model with its running turn, if any, written to its end.
fn settle(model: Model) -> Model {
  case model.running {
    Some(steps) ->
      Model(
        ..model,
        settled: list.append(model.settled, [steps]),
        running: None,
      )
    None -> model
  }
}

fn next_model(model: Model, cmd: Cmd) -> Model {
  case cmd {
    Append(turns:, steps:) -> {
      let done = settle(model)
      Model(
        ..done,
        settled: list.append(done.settled, list.repeat(steps, turns)),
      )
    }
    Open(steps:) -> Model(..settle(model), running: Some(steps))
    Resume(steps:) -> Model(..settle(model), resumed: Some(steps))
    Settle -> settle(model)
    Press | Read | Fold(..) | Latest | Tick | Serve | Refuse -> model
  }
}

// --- the history the model stands for ----------------------------------------

// The records of the model's history, oldest first. A running turn is its
// records without the answer, which is the last.
fn records(model: Model) -> List(snapshot.Item) {
  let held = case model.running {
    None -> lane_fixture.reading(model.settled)
    Some(steps) -> {
      let all = lane_fixture.reading(list.append(model.settled, [steps]))
      list.take(all, list.length(all) - 1)
    }
  }
  case model.resumed {
    Some(steps) -> lane_fixture.resumed(held, steps)
    None -> held
  }
}

// The capture a gateway sends: the newest hundred records, `main` running
// while a turn does.
fn capture(model: Model) {
  let held = records(model)
  let operation = case model.running {
    Some(_) -> Some(lane_fixture.main_op())
    None -> None
  }
  lane_fixture.since(held, int.max(1, list.length(held) - 99), operation)
}

// --- the system under test ---------------------------------------------------

/// The page, the subject it writes to, and the ledger the oracle keeps: the
/// requests the page has written and the test has not yet answered.
type Sut {
  Sut(
    page: component.Model(page_fixture.Wire),
    wire: page_fixture.Wire,
    out: List(String),
    /// Whether a press is still owed its rows.
    asking: Asking,
  )
}

/// Whether the reader's last press has been answered.
type Asking {
  /// Nothing is owed.
  Quiet

  /// The reader pressed "Load older" on a page with older rows, and the
  /// page's reads are not all answered.
  Asked
}

fn new_sut() -> Sut {
  let wire = process.new_subject()
  Sut(page: page_fixture.ready(wire, "operator"), wire:, out: [], asking: Quiet)
}

fn broken(tag: String, detail: String) -> Result(a, Violation) {
  Error(Violation(tag:, detail:))
}

fn is_snapshot(frame: String) -> Bool {
  string.contains(frame, "\"cmd\":\"snapshot")
  || string.contains(frame, "\"cmd\":\"subscribe\"")
}

fn is_history(frame: String) -> Bool {
  string.contains(frame, "\"cmd\":\"history")
}

// Applies one command to the page and says which requests the test answered,
// by identity.
fn step(
  sut: Sut,
  model: Model,
  cmd: Cmd,
) -> #(component.Model(page_fixture.Wire), List(Int)) {
  let after = next_model(model, cmd)
  case cmd {
    Append(..) | Open(..) | Resume(..) | Settle -> #(
      component.apply(sut.page, [capture(after)]),
      [],
    )
    Press -> #(
      page_fixture.run(sut.page, component.update, [component.OlderRequested]),
      [],
    )
    Fold(index:) ->
      case fold_at(sut.page, index) {
        Ok(fold) -> #(
          page_fixture.run(sut.page, component.update, [
            component.FoldToggled(fold),
          ]),
          [],
        )
        Error(Nil) -> #(sut.page, [])
      }
    Latest -> #(
      page_fixture.run(sut.page, component.update, [component.LatestRequested]),
      [],
    )
    Tick -> #(
      page_fixture.run(sut.page, component.update, [component.Ticked]),
      [],
    )
    Refuse ->
      case list.find(sut.out, is_history) {
        Ok(read) -> #(
          page_fixture.run(sut.page, component.update, [
            component.Arrived([
              page_fixture.refusal(page_fixture.request_id(read)),
            ]),
          ]),
          [page_fixture.request_id(read)],
        )
        Error(Nil) -> #(sut.page, [])
      }
    Serve -> served(sut, sut.page, model)

    Read ->
      served(
        sut,
        page_fixture.run(sut.page, component.update, [component.OlderRequested]),
        model,
      )
  }
}

// The gateway answers every read `page` has out, from the session's history,
// and says which requests it answered.
fn served(
  sut: Sut,
  page: component.Model(page_fixture.Wire),
  model: Model,
) -> #(component.Model(page_fixture.Wire), List(Int)) {
  let #(page, written) =
    lane_fixture.served(
      page,
      sut.wire,
      records(model),
      capture(model),
      "operator",
    )
  #(page, list.map(written, page_fixture.request_id))
}

// The number of the fold at `index`, modulo the folds the page draws a
// button for: the dividers of its closed turns.
fn fold_at(
  page: component.Model(page_fixture.Wire),
  index: Int,
) -> Result(Int, Nil) {
  let folds =
    list.filter_map(component.pieces(page), fn(piece) {
      case piece {
        turns.Work(id: Some(id), ..) -> Ok(id)
        turns.Work(id: None, ..)
        | turns.Plain(..)
        | turns.Prompt(..)
        | turns.Commentary(..)
        | turns.Spawned(..)
        | turns.Returned(..)
        | turns.Nudged(..)
        | turns.Peer(..)
        | turns.Sibling(..)
        | turns.Missed(..)
        | turns.Decided(..) -> Error(Nil)
      }
    })
  list.drop(folds, index % int.max(list.length(folds), 1)) |> list.first
}

// Whether the reader has a closed turn's fold open, which is what the folds'
// reserve of rows is for.
fn reader_opened(page: component.Model(page_fixture.Wire)) -> Bool {
  list.any(component.pieces(page), fn(piece) {
    case piece {
      turns.Work(id: Some(_), folding: turns.Unfolded(..), ..)
      | turns.Work(id: Some(_), folding: turns.Reading, ..) -> True
      turns.Work(..)
      | turns.Plain(..)
      | turns.Prompt(..)
      | turns.Commentary(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..) -> False
    }
  })
}

// The limit of rows a page in `paging` holds, beside its folds' reserve.
fn row_bound(
  paging: component.Paging,
  page: component.Model(page_fixture.Wire),
) -> Int {
  let limit = case paging {
    component.Tail -> component.live_rows
    component.Paged | component.Full | component.Crowded | component.Browsing ->
      component.held_rows
  }
  case reader_opened(page) {
    True -> limit + fold_budget.fold_rows
    False -> limit
  }
}

// The paging state `after` a command that began in `before` is one the
// command could cause.
fn may_move(
  before: component.Paging,
  after: component.Paging,
  cmd: Cmd,
) -> Bool {
  case before, after, cmd {
    _, component.Tail, Latest -> True
    component.Tail, component.Tail, _ -> True
    component.Tail, _, _ -> True
    _, component.Tail, _ -> False
    component.Full, component.Full, _ -> True
    component.Full, component.Browsing, Press -> True
    component.Full, component.Browsing, Read -> True
    component.Full, _, _ -> False
    component.Browsing, component.Browsing, _ -> True
    component.Browsing, _, _ -> False
    component.Paged, _, _ | component.Crowded, _, _ -> True
  }
}

// The requests the page has written and the test has not answered: what was
// on the wire before and what the command added, less what it answered. They
// are put back, so the gateway's `served` finds them.
fn unanswered(sut: Sut, answered: List(Int)) -> List(String) {
  let out =
    page_fixture.sent(sut.wire)
    |> list.filter(fn(frame) { !is_snapshot(frame) })
    |> list.filter(fn(frame) {
      !list.contains(answered, page_fixture.request_id(frame))
    })
  list.each(out, process.send(sut.wire, _))
  out
}

// Whether the reader's press is still owed an answer. A press is a want, so
// it holds from the press until a command that answers or retires the page's
// reads leaves none out, or until the reader returns to the latest.
fn asking_after(
  asking: Asking,
  cmd: Cmd,
  before: lane.Top,
  out: List(String),
) -> Asking {
  case cmd, before {
    Press, lane.Earlier -> Asked
    Latest, _ -> Quiet
    Serve, _ | Read, _ | Refuse, _ ->
      case list.any(out, is_history) {
        True -> asking
        False -> Quiet
      }
    Append(..), _
    | Open(..), _
    | Resume(..), _
    | Settle, _
    | Press, _
    | Fold(..), _
    | Tick, _
    -> asking
  }
}

// `paging.rows`: what the page draws is within its limit, and within the
// folds' reserve beyond it only while the reader has a closed turn's fold open.
fn rows_bounded(
  page: component.Model(page_fixture.Wire),
  paging: component.Paging,
) -> Result(Nil, Violation) {
  let rows = list.length(component.rows(page))
  case rows > row_bound(paging, page) {
    True ->
      broken(
        "paging.rows",
        int.to_string(rows) <> " rows drawn in " <> string.inspect(paging),
      )
    False -> Ok(Nil)
  }
}

// `paging.one_read`: the lane has one request out at a time.
fn one_read(out: List(String)) -> Result(Nil, Violation) {
  case out {
    [] | [_] -> Ok(Nil)
    [_, _, ..] ->
      broken("paging.one_read", "requests out: " <> string.inspect(out))
  }
}

// `paging.loading`: a press that found older rows leaves the lane saying it
// is loading until the page's reads are answered.
fn loading(
  page: component.Model(page_fixture.Wire),
  asking: Asking,
) -> Result(Nil, Violation) {
  case asking, component.top(page) {
    Asked, lane.Loading | Quiet, _ -> Ok(Nil)
    Asked, top ->
      broken(
        "paging.loading",
        "a press is owed its rows and the lane says " <> string.inspect(top),
      )
  }
}

// `paging.moves`: the paging state is one the command could cause.
fn moved(
  before: component.Paging,
  after: component.Paging,
  cmd: Cmd,
) -> Result(Nil, Violation) {
  case may_move(before, after, cmd) {
    True -> Ok(Nil)
    False ->
      broken(
        "paging.moves",
        string.inspect(before) <> " became " <> string.inspect(after),
      )
  }
}

// `paging.full`: a press on a page that cannot grow does not grow it.
fn full_press(
  before: #(component.Paging, lane.Top),
  after: component.Paging,
  cmd: Cmd,
) -> Result(Nil, Violation) {
  case cmd {
    Press | Read -> pressed_full(before, after)
    Append(..)
    | Open(..)
    | Resume(..)
    | Settle
    | Fold(..)
    | Latest
    | Tick
    | Serve
    | Refuse -> Ok(Nil)
  }
}

// The press itself: from a page the paging doc says enters `Browsing`.
fn pressed_full(
  before: #(component.Paging, lane.Top),
  after: component.Paging,
) -> Result(Nil, Violation) {
  case before, after {
    #(component.Full, lane.Earlier), component.Browsing
    | #(component.Crowded, lane.Earlier), component.Browsing
    -> Ok(Nil)
    #(component.Full, lane.Earlier), _
    | #(component.Crowded, lane.Earlier), _
    ->
      broken(
        "paging.full",
        "a press on a "
          <> string.inspect(before.0)
          <> " page left it "
          <> string.inspect(after),
      )
    #(component.Tail, _), _
    | #(component.Paged, _), _
    | #(component.Browsing, _), _
    | #(component.Full, lane.Beginning), _
    | #(component.Full, lane.Loading), _
    | #(component.Full, lane.Full(_)), _
    | #(component.Full, lane.Crowded), _
    | #(component.Crowded, lane.Beginning), _
    | #(component.Crowded, lane.Loading), _
    | #(component.Crowded, lane.Full(_)), _
    | #(component.Crowded, lane.Crowded), _
    -> Ok(Nil)
  }
}

// Checks the promises that hold after every event.
fn observe(
  sut: Sut,
  stepped: #(component.Model(page_fixture.Wire), List(Int)),
  before: #(component.Paging, lane.Top),
  cmd: Cmd,
) -> Result(Sut, Violation) {
  let #(page, answered) = stepped
  let out = unanswered(sut, answered)
  let paging = component.paging(page)
  let asking = asking_after(sut.asking, cmd, before.1, out)
  use Nil <- result.try(one_read(out))
  use Nil <- result.try(rows_bounded(page, paging))
  use Nil <- result.try(loading(page, asking))
  use Nil <- result.try(full_press(before, paging, cmd))
  use Nil <- result.try(moved(before.0, paging, cmd))
  Ok(Sut(..sut, page:, out:, asking:))
}

fn execute(sut: Sut, model: Model, cmd: Cmd) -> Result(Sut, Violation) {
  let before = #(component.paging(sut.page), component.top(sut.page))
  observe(sut, step(sut, model, cmd), before, cmd)
}

// --- the differential --------------------------------------------------------

// The dividers a page draws, by the key of the turn's input.
fn dividers(
  page: component.Model(page_fixture.Wire),
) -> List(#(String, turns.Worked)) {
  list.filter_map(component.pieces(page), fn(piece) {
    case piece {
      turns.Work(key:, worked:, ..) -> Ok(#(key, worked))
      turns.Plain(..)
      | turns.Prompt(..)
      | turns.Commentary(..)
      | turns.Spawned(..)
      | turns.Returned(..)
      | turns.Nudged(..)
      | turns.Peer(..)
      | turns.Sibling(..)
      | turns.Missed(..)
      | turns.Decided(..) -> Error(Nil)
    }
  })
}

// The session settled, the live page given every read it asked for, and a
// second page opened on the same history. Says how many dividers the two
// pages both draw, and which of those differ.
fn compared(
  sut: Sut,
  model: Model,
) -> #(Int, List(#(String, turns.Worked, Option(turns.Worked)))) {
  let done = settle(model)
  let live =
    component.apply(sut.page, [capture(done)])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.serve(sut.wire, records(done), capture(done))
  let wire = process.new_subject()
  let fresh =
    page_fixture.ready(wire, "operator")
    |> component.apply([capture(done)])
    |> page_fixture.run(component.update, [component.Ticked])
    |> lane_fixture.serve(wire, records(done), capture(done))
  let mine = dividers(live)
  let shared =
    list.filter(dividers(fresh), fn(theirs) {
      list.key_find(mine, theirs.0) != Error(Nil)
    })
  let differing =
    list.filter_map(shared, fn(theirs) {
      let ours = list.key_find(mine, theirs.0)
      case ours == Ok(theirs.1) {
        True -> Error(Nil)
        False -> Ok(#(theirs.0, theirs.1, option.from_result(ours)))
      }
    })
  #(list.length(shared), differing)
}

// A divider both pages draw is one divider.
fn finish(sut: Sut, model: Model) -> Result(Nil, Violation) {
  case compared(sut, model).1 {
    [] -> Ok(Nil)
    [#(key, opened, watched), ..] ->
      broken(
        "paging.divider",
        "the page opened after draws "
          <> key
          <> " as "
          <> string.inspect(opened)
          <> " and the page that watched draws "
          <> string.inspect(watched),
      )
  }
}

// --- generators --------------------------------------------------------------

fn command(model: Model) -> qcheck.Generator(Cmd) {
  case model.settled, model.resumed {
    [], _ -> appending()
    [_, ..], Some(_) -> reading()
    [_, ..], None -> events()
  }
}

// A history of many short turns, so the page has older turns to ask for.
fn appending() -> qcheck.Generator(Cmd) {
  qcheck.map2(
    qcheck.bounded_int(from: 10, to: 150),
    qcheck.bounded_int(from: 0, to: 3),
    Append,
  )
}

// The events once the history can grow no more.
fn reading() -> qcheck.Generator(Cmd) {
  qcheck.from_weighted_generators(#(6, qcheck.return(Read)), [
    #(3, qcheck.map(qcheck.bounded_int(from: 0, to: 40), Fold)),
    #(2, qcheck.return(Press)),
    #(1, qcheck.return(Latest)),
    #(1, qcheck.return(Tick)),
    #(2, qcheck.return(Serve)),
    #(1, qcheck.return(Refuse)),
    #(1, qcheck.return(Settle)),
  ])
}

// Every event, weighted toward the reader reading deeper, which is what
// carries a page from `Tail` toward `Full` and `Browsing`.
fn events() -> qcheck.Generator(Cmd) {
  qcheck.from_weighted_generators(#(3, appending()), [
    #(4, qcheck.map(qcheck.bounded_int(from: 10, to: 60), Open)),
    #(1, qcheck.return(Settle)),
    #(1, qcheck.map(qcheck.bounded_int(from: 0, to: 6), Resume)),
    #(2, qcheck.return(Press)),
    #(6, qcheck.return(Read)),
    #(3, qcheck.map(qcheck.bounded_int(from: 0, to: 40), Fold)),
    #(1, qcheck.return(Latest)),
    #(1, qcheck.return(Tick)),
    #(2, qcheck.return(Serve)),
    #(1, qcheck.return(Refuse)),
  ])
}

// A resumed history cannot grow, and only a history with a turn can resume.
fn precondition(model: Model, cmd: Cmd) -> statem.Admission {
  case cmd, model.resumed, model.settled {
    Append(..), Some(_), _ | Open(..), Some(_), _ | Resume(..), Some(_), _ ->
      Reject
    Resume(..), None, [] -> Reject
    Resume(..), None, [_, ..]
    | Append(..), None, _
    | Open(..), None, _
    | Settle, _, _
    | Press, _, _
    | Read, _, _
    | Fold(..), _, _
    | Latest, _, _
    | Tick, _, _
    | Serve, _, _
    | Refuse, _, _
    -> Admit
  }
}

fn spec() -> Spec(Model, Cmd, Sut) {
  Spec(
    initial: Model(settled: [], running: None, resumed: None),
    command:,
    precondition:,
    next_model:,
    new_sut:,
    execute:,
    finish:,
    teardown: fn(_) { Nil },
  )
}

fn config() -> statem.Config {
  statem.default_config(seed:)
  |> statem.with_test_count(test_count)
  |> statem.with_max_commands(max_commands)
}

// --- the test ----------------------------------------------------------------

pub fn the_page_keeps_its_promises_under_any_sequence_test() {
  case statem.check(spec(), config()) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, describe)
  }
}

// A property over a generator that never reaches the interesting states is a
// green light that means nothing, so this walks the same sequences and asserts
// the walk meets every paging state the promises are about, a read left out, a
// fold the reader opened, and a final comparison with dividers to compare, one
// of them after a turn resumed.
pub fn the_generated_sequences_reach_the_states_the_promises_are_about_test() {
  let walks =
    list.map(counting(0, census_runs - 1, []), fn(run) {
      walk(statem.commands(spec(), config(), run))
    })
  let states = list.flat_map(walks, fn(walked) { walked.states })
  assert list.contains(states, component.Paged)
  assert list.contains(states, component.Full)
  assert list.contains(states, component.Crowded)
  assert list.contains(states, component.Browsing)
  assert list.any(walks, fn(walked) { walked.reads > 0 })
  assert list.any(walks, fn(walked) { walked.folds > 0 })
  assert list.any(walks, fn(walked) { walked.shared >= 20 })
  assert list.any(walks, fn(walked) { walked.resumed >= 1 })
}

/// What one sequence reached.
type Walked {
  Walked(
    /// The paging state after each command.
    states: List(component.Paging),
    /// How many commands left a history read out.
    reads: Int,
    /// How many commands left a closed turn's fold open.
    folds: Int,
    /// How many dividers the final comparison had to compare.
    shared: Int,
    /// How many of those a resumed turn contributed: zero unless the history
    /// ended in a resume.
    resumed: Int,
  )
}

// Runs a sequence through `execute`, as `check` would, and records where it
// went.
fn walk(commands: List(Cmd)) -> Walked {
  let #(sut, model, seen) =
    list.fold(
      commands,
      #(new_sut(), spec().initial, empty_walk()),
      fn(acc, cmd) {
        let #(sut, model, seen) = acc
        let assert Ok(next) = execute(sut, model, cmd) as "a census run failed"
        #(next, next_model(model, cmd), visited(seen, next))
      },
    )
  let shared = compared(sut, model).0
  Walked(..seen, shared:, resumed: case model.resumed {
    Some(_) -> shared
    None -> 0
  })
}

fn empty_walk() -> Walked {
  Walked(states: [], reads: 0, folds: 0, shared: 0, resumed: 0)
}

// The census after one more command.
fn visited(seen: Walked, sut: Sut) -> Walked {
  Walked(
    ..seen,
    states: [component.paging(sut.page), ..seen.states],
    reads: seen.reads + count_if(list.any(sut.out, is_history)),
    folds: seen.folds + count_if(reader_opened(sut.page)),
  )
}

// One when the question holds, else nothing: a tally of commands.
fn count_if(holds: Bool) -> Int {
  case holds {
    True -> 1
    False -> 0
  }
}

// The integers `from` to `to`, in order.
fn counting(from: Int, to: Int, acc: List(Int)) -> List(Int) {
  case to < from {
    True -> acc
    False -> counting(from, to - 1, [to, ..acc])
  }
}
