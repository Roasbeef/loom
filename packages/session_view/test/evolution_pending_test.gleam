//// The tracker of staged evolution selections: example tests for each
//// documented transition, and a model-based test of the whole machine.
////
//// A selection of the running session's extension is not instant. The daemon
//// answers `queued`, finishes later, and reports the end only to a caller that
//// asks `status` with the request's identity. `evolution_pending` keeps that
//// identity so a person never sees it, and decides when the lane polls, when
//// it gives up, and what a reconnect forgets.
////
//// ## The model
////
//// The abstract state is a clock, the tracked rows in order, the request the
//// lane awaits, and two counters. A row is an identity, a candidate, a stage
//// tag, a deadline and a poll time. `predict` advances it by the rules the
//// module documents, written out here as a list rather than as the module's
//// own functions, so a disagreement is a bug in one of them.
////
//// ## The rules, by tag
////
//// - `model`: after every command the real tracker projects to the model's
////   rows and awaiting identity. This is the rule that holds the others
////   together; the tags below name the facts it checks that a reader of the
////   module doc would expect independently.
//// - `unique`: no identity is minted twice, across reconnects.
//// - `bounded`: at most sixteen requests are tracked.
//// - `awaiting`: the awaited request exists and has not settled.
//// - `cadence`: a request is polled only once its poll time has come.
////
//// A command names no identity by value. `Reply` answers whichever request is
//// awaited, and `Board` lists rows by position, so deleting a command leaves
//// the later ones meaningful and a failure shrinks to a short list. A run is
//// reproduced from the seed and run number alone. The seeds are constants.

import core/json
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import qcheck
import session_view/evolution
import session_view/evolution_pending as pending
import statem

// --- examples -----------------------------------------------------------------

const session = "0198c0de-0000"

// The numbers from one to `size`.
fn counted(size: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, size), fn(_, position) { position + 1 })
}

fn begun(
  tracker: pending.Tracker,
  now: Int,
  candidate: String,
) -> #(pending.Tracker, String) {
  // An example that begins twice has answered the first request already, so
  // the awaited reply is cleared here and `begin`'s own refusal is tested apart.
  let answered = pending.Tracker(..tracker, awaiting: None)
  let assert Ok(made) = pending.begin(answered, session, now, candidate, "fmt")
  made
}

pub fn a_request_is_refused_while_a_reply_is_awaited_test() {
  let #(tracker, _) = begun(pending.new(), 0, "cand")
  let refused = pending.begin(tracker, session, 5, "other", "fmt")
  assert refused |> result.is_error
  assert tracker.awaiting != None
}

pub fn the_next_due_instant_is_the_earliest_poll_or_deadline_test() {
  assert pending.next_due(pending.new()) == None
  let #(tracker, _) = begun(pending.new(), 1000, "cand")
  assert pending.next_due(tracker) == Some(1000 + pending.window_ms)
  let #(tracker, _) =
    pending.answered(tracker, evolution.InFlight(evolution.Queued), 1100)
  assert pending.next_due(tracker) == Some(1100 + pending.poll_ms)
  let #(tracker, _) = pending.expire(tracker, 1000 + pending.window_ms)
  assert pending.next_due(tracker) == None
}

fn only(tracker: pending.Tracker) -> pending.Tracked {
  let assert [tracked] = tracker.requests
  tracked
}

pub fn an_identity_names_the_session_the_candidate_and_the_count_test() {
  let #(tracker, id) = begun(pending.new(), 5000, "3f9a0c2e1b7d")
  assert id == "ui-0198c0de-5000-3f9a0c2e-1"
  let #(_, second) = begun(tracker, 5000, "3f9a0c2e1b7d")
  assert second == "ui-0198c0de-5000-3f9a0c2e-2"
    as "two requests in one millisecond differ by the counter"
}

pub fn a_negative_clock_never_puts_a_sign_in_an_identity_test() {
  let #(_, id) = begun(pending.new(), -5000, "aaaabbbb")
  assert id == "ui-0198c0de-5000-aaaabbbb-1"
}

pub fn a_new_request_waits_for_the_daemons_first_reply_test() {
  let #(tracker, id) = begun(pending.new(), 1000, "cand")
  let tracked = only(tracker)
  assert tracked.stage == pending.Submitted
  assert tracked.deadline_ms == 1000 + pending.window_ms
  assert tracker.awaiting == Some(id)
  assert pending.poll(tracker, 1_000_000) == None
    as "nothing is polled while its first reply is awaited"
}

pub fn a_queued_reply_starts_the_polling_cadence_test() {
  let #(tracker, id) = begun(pending.new(), 1000, "cand")
  let #(tracker, moved) =
    pending.answered(tracker, evolution.InFlight(evolution.Queued), 1100)
  let assert Some(tracked) = moved
  assert tracked.stage == pending.Staging(evolution.Queued)
  assert tracked.next_poll_ms == 1100 + pending.poll_ms
  assert tracker.awaiting == None
  assert pending.poll(tracker, 1100 + pending.poll_ms - 1) == None
  let assert Some(#(polled, polled_id)) =
    pending.poll(tracker, 1100 + pending.poll_ms)
  assert polled_id == id
  assert polled.awaiting == Some(id)
  assert pending.poll(polled, 1_000_000) == None
    as "one command is out at a time"
}

pub fn each_report_moves_the_request_to_its_stage_test() {
  let at = fn(report) {
    let #(tracker, _) = begun(pending.new(), 0, "cand")
    let #(tracker, moved) = pending.answered(tracker, report, 10)
    assert moved == Some(only(tracker))
    only(tracker).stage
  }
  assert at(evolution.InFlight(evolution.Running))
    == pending.Staging(evolution.Running)
  assert at(evolution.DurableOnly(Some(2))) == pending.Publishing
  assert at(evolution.Done(Some(2))) == pending.Landed(Some(2))
  assert at(evolution.Rejected("busy")) == pending.Refused("busy")
  assert at(evolution.Forgotten) == pending.Vanished
}

pub fn a_reply_with_no_request_awaiting_changes_nothing_test() {
  let tracker = pending.new()
  assert pending.answered(tracker, evolution.Done(None), 0) == #(tracker, None)
  let #(tracker, _) = begun(tracker, 0, "cand")
  let #(settled, _) = pending.answered(tracker, evolution.Done(None), 5)
  let #(late, moved) =
    pending.answered(
      pending.Tracker(..settled, awaiting: tracker.awaiting),
      evolution.Rejected("late"),
      9,
    )
  assert moved == None as "a reply after the request settled belongs to nobody"
  assert only(late).stage == pending.Landed(None)
}

pub fn a_refused_select_is_dropped_and_a_refused_poll_is_asked_again_test() {
  let #(tracker, _) = begun(pending.new(), 0, "cand")
  assert pending.refused(tracker, 10).requests == []
  let #(tracker, id) =
    pending.answered(tracker, evolution.InFlight(evolution.Running), 10)
    |> fn(pair) { #(pair.0, only(pair.0).request_id) }
  let assert Some(#(polled, _)) = pending.poll(tracker, 5000)
  assert polled.awaiting == Some(id)
  let refused = pending.refused(polled, 5000)
  assert refused.awaiting == None
  assert only(refused).next_poll_ms == 5000 + pending.poll_ms
  assert only(refused).stage == pending.Staging(evolution.Running)
}

pub fn a_request_that_outlives_its_deadline_times_out_test() {
  let #(tracker, id) = begun(pending.new(), 0, "cand")
  let #(waiting, _) =
    pending.answered(tracker, evolution.InFlight(evolution.Queued), 100)
  let #(early, none) = pending.expire(waiting, pending.window_ms - 1)
  assert none == pending.NoneExpired
  assert early == waiting
  let assert Some(#(polling, _)) = pending.poll(waiting, 5000)
  assert polling.awaiting == Some(id)
  let #(late, expired) = pending.expire(polling, pending.window_ms)
  assert expired == pending.Expired
  assert only(late).stage == pending.TimedOut
  assert late.awaiting == None as "a reply that still arrives belongs to nobody"
  assert pending.expire(late, pending.window_ms * 2).1 == pending.NoneExpired
}

pub fn a_reconnect_forgets_the_requests_and_keeps_the_count_test() {
  let #(tracker, first) = begun(pending.new(), 0, "cand")
  let forgotten = pending.reset(tracker)
  assert forgotten.requests == []
  assert forgotten.awaiting == None
  let #(_, second) = begun(forgotten, 0, "cand")
  assert first != second
}

fn board_listing(
  pending_rows: List(#(String, String, String)),
) -> evolution.Board {
  let rows =
    list.map(pending_rows, fn(row) {
      let #(request_id, state, candidate_id) = row
      json.Object([
        #("request_id", json.String(request_id)),
        #("state", json.String(state)),
        #("candidate_id", json.String(candidate_id)),
        #("expires_at_ms", json.Int(1)),
      ])
    })
  let assert Ok(board) =
    evolution.decode_board(json.Object([#("pending", json.Array(rows))]))
  board
}

pub fn the_next_board_restores_what_a_reconnect_forgot_test() {
  let lost = pending.reset(begun(pending.new(), 0, "cand").0)
  let board =
    board_listing([
      #("ui-held", "running", "cand"),
      #("ui-queued", "queued", "x"),
    ])
  let restored = pending.restore(lost, board, 7000)
  let assert [first, second] = restored.requests
  assert first.request_id == "ui-held"
  assert first.stage == pending.Staging(evolution.Running)
  assert first.deadline_ms == 7000 + pending.window_ms
  assert second.stage == pending.Staging(evolution.Queued)
  let assert Some(#(_, id)) = pending.poll(restored, 7000 + pending.poll_ms)
  assert id == "ui-held"
}

pub fn a_board_drops_settled_requests_and_corrects_a_phase_test() {
  let #(tracker, id) = begun(pending.new(), 0, "cand")
  let #(tracker, _) =
    pending.answered(tracker, evolution.InFlight(evolution.Queued), 10)
  let #(tracker, other) = begun(tracker, 20, "other")
  let #(tracker, _) = pending.answered(tracker, evolution.Done(Some(1)), 30)
  let board = board_listing([#(id, "running", "cand")])
  let restored = pending.restore(tracker, board, 100)
  let assert [kept] = restored.requests
  assert kept.request_id == id
  assert kept.stage == pending.Staging(evolution.Running)
  assert list.all(restored.requests, fn(row) { row.request_id != other })
}

// A staging request that the board no longer lists has left the queue. If its
// candidate is the selected one the selection committed, and the row says so
// from the board instead of staying "staging" above a live generation; if the
// candidate is not selected the board cannot say how it ended, so the row waits
// for the next status poll.
pub fn a_board_settles_a_staging_request_whose_candidate_is_selected_test() {
  let #(tracker, id) = begun(pending.new(), 0, "cand")
  let #(tracker, _) =
    pending.answered(tracker, evolution.InFlight(evolution.Running), 10)
  let selected = fn(live: Bool) {
    let assert Ok(board) =
      evolution.decode_board(
        json.Object([
          #(
            "candidates",
            json.Array([
              json.Object([
                #("candidate_id", json.String("cand")),
                #("name", json.String("fmt_check")),
                #("kind", json.String("extension")),
                #(
                  "scope",
                  json.Object([
                    #("kind", json.String("session")),
                    #("session", json.String("s")),
                  ]),
                ),
                #("identity_current", json.Bool(True)),
                #(
                  "selected",
                  json.Object([
                    #("generation", json.Int(4)),
                    #("evidence_id", json.String("e1")),
                  ]),
                ),
              ]),
            ]),
          ),
          #(
            "selections",
            json.Array([
              json.Object([
                #(
                  "scope",
                  json.Object([
                    #("kind", json.String("session")),
                    #("session", json.String("s")),
                  ]),
                ),
                #("name", json.String("fmt_check")),
                #("candidate_id", json.String("cand")),
                #("evidence_id", json.String("e1")),
                #("generation", json.Int(4)),
                #("published", json.Bool(live)),
              ]),
            ]),
          ),
        ]),
      )
    board
  }
  let live = pending.restore(tracker, selected(True), 100)
  assert { only(live) }.stage == pending.Landed(Some(4))
  assert { only(live) }.request_id == id
  let durable = pending.restore(tracker, selected(False), 100)
  assert { only(durable) }.stage == pending.Publishing

  // No selected candidate on the board: left staging for the status poll.
  let unselected = pending.restore(tracker, board_listing([]), 100)
  assert { only(unselected) }.stage == pending.Staging(evolution.Running)
}

pub fn the_tracker_is_bounded_and_makes_room_from_the_settled_test() {
  let full =
    list.fold(counted(pending.limit), pending.new(), fn(tracker, _) {
      let #(tracker, _) = begun(tracker, 0, "cand")
      let #(tracker, _) =
        pending.answered(tracker, evolution.InFlight(evolution.Queued), 1)
      tracker
    })
  assert list.length(full.requests) == pending.limit
  assert pending.begin(full, session, 5, "cand", "fmt") |> result.is_error
  let #(settled, _) =
    pending.answered(
      pending.Tracker(..full, awaiting: Some(only_first(full).request_id)),
      evolution.Done(None),
      2,
    )
  let assert Ok(#(room, id)) = pending.begin(settled, session, 5, "cand", "fmt")
  assert list.length(room.requests) == pending.limit
  assert list.all(settled.requests, fn(row) { row.request_id != id })
  assert list.all(room.requests, fn(row) { row != only_first(full) })
    as "the settled request made the room"
}

fn only_first(tracker: pending.Tracker) -> pending.Tracked {
  let assert [first, ..] = tracker.requests
  first
}

pub fn the_words_say_where_a_request_stands_test() {
  let tracked = fn(stage) {
    pending.Tracked(
      request_id: "r",
      candidate_id: "3f9a0c2e1b",
      name: "fmt_check",
      stage:,
      deadline_ms: 60_000,
      next_poll_ms: 0,
    )
  }
  assert pending.words(tracked(pending.Staging(evolution.Running)), 12_000)
    == "fmt_check: staging, 48 s left"
  assert pending.words(tracked(pending.Staging(evolution.Queued)), 12_000)
    == "fmt_check: queued, 48 s left"
  assert pending.words(tracked(pending.Publishing), 59_000)
    == "fmt_check: committed, publishing, 1 s left"
  assert pending.words(tracked(pending.Landed(Some(4))), 0)
    == "fmt_check: generation 4 is live"
  assert pending.words(tracked(pending.Refused("busy")), 0)
    == "fmt_check: the selection failed: busy"
  assert pending.words(tracked(pending.Staging(evolution.Running)), 90_000)
    == "fmt_check: staging, 0 s left"
  assert string.starts_with(
    pending.words(pending.Tracked(..tracked(pending.Submitted), name: ""), 0),
    "3f9a0c2e: ",
  )
}

// --- the model ------------------------------------------------------------------

type Tag {
  Submitted
  Queued
  Running
  Publishing
  Landed
  Rejected
  Lost
  TimedOut
}

type Row {
  Row(ident: String, candidate: Int, tag: Tag, deadline: Int, next_poll: Int)
}

type Model {
  Model(
    now: Int,
    rows: List(Row),
    awaiting: Option(String),
    minted: Int,
    strangers: Int,
  )
}

type Kind {
  ReplyQueued
  ReplyRunning
  ReplyDurable
  ReplyDone
  ReplyFailed
  ReplyForgotten
}

type Command {
  Begin(candidate: Int)
  Advance(ms: Int)
  Reply(kind: Kind)
  Refuse
  Board(listing: Int, strangers: Int)
  Reconnect
}

const window = 60_000

const cadence = 2000

const limit = 16

fn is_settled(tag: Tag) -> Bool {
  case tag {
    Landed | Rejected | Lost | TimedOut -> True
    Submitted | Queued | Running | Publishing -> False
  }
}

fn is_due(row: Row, now: Int) -> Bool {
  case row.tag {
    Queued | Running | Publishing -> now >= row.next_poll
    Submitted | Landed | Rejected | Lost | TimedOut -> False
  }
}

fn start() -> Model {
  Model(now: 10_000, rows: [], awaiting: None, minted: 0, strangers: 0)
}

fn predict(model: Model, command: Command) -> Model {
  case command {
    Begin(candidate) -> begin(model, candidate)
    Advance(ms) -> advance(model, ms)
    Reply(kind) -> reply(model, kind)
    Refuse -> refuse(model)
    Board(listing, strangers) -> board(model, listing, strangers)
    Reconnect -> Model(..model, rows: [], awaiting: None)
  }
}

fn begin(model: Model, candidate: Int) -> Model {
  let room = case model.awaiting, list.length(model.rows) < limit {
    Some(_), _ -> Error(Nil)
    None, True -> Ok(model.rows)
    None, False ->
      case list.find(model.rows, fn(row) { is_settled(row.tag) }) {
        Ok(oldest) -> Ok(list.filter(model.rows, fn(row) { row != oldest }))
        Error(Nil) -> Error(Nil)
      }
  }
  case room {
    Error(Nil) -> model
    Ok(rows) -> {
      let minted = model.minted + 1
      let ident = "m" <> int.to_string(minted)
      Model(
        ..model,
        rows: list.append(rows, [
          Row(
            ident,
            candidate,
            Submitted,
            model.now + window,
            model.now + window,
          ),
        ]),
        awaiting: Some(ident),
        minted:,
      )
    }
  }
}

// Time passes, the deadlines are judged, and the next due request is polled,
// which is what one tick of the lane does.
fn advance(model: Model, ms: Int) -> Model {
  let now = model.now + ms
  let rows =
    list.map(model.rows, fn(row) {
      case !is_settled(row.tag) && now >= row.deadline {
        True -> Row(..row, tag: TimedOut)
        False -> row
      }
    })
  let awaiting = case model.awaiting {
    Some(ident) ->
      case list.find(rows, fn(row) { row.ident == ident }) {
        Ok(Row(tag: TimedOut, ..)) | Error(Nil) -> None
        Ok(_) -> Some(ident)
      }
    None -> None
  }
  let awaiting = case awaiting {
    Some(_) -> awaiting
    None ->
      case list.find(rows, fn(row) { is_due(row, now) }) {
        Ok(row) -> Some(row.ident)
        Error(Nil) -> None
      }
  }
  Model(..model, now:, rows:, awaiting:)
}

fn reply(model: Model, kind: Kind) -> Model {
  case model.awaiting {
    None -> model
    Some(ident) -> {
      let rows =
        list.map(model.rows, fn(row) {
          case row.ident == ident && !is_settled(row.tag) {
            True ->
              case kind {
                ReplyQueued ->
                  Row(..row, tag: Queued, next_poll: model.now + cadence)
                ReplyRunning ->
                  Row(..row, tag: Running, next_poll: model.now + cadence)
                ReplyDurable ->
                  Row(..row, tag: Publishing, next_poll: model.now + cadence)
                ReplyDone -> Row(..row, tag: Landed)
                ReplyFailed -> Row(..row, tag: Rejected)
                ReplyForgotten -> Row(..row, tag: Lost)
              }
            False -> row
          }
        })
      Model(..model, rows:, awaiting: None)
    }
  }
}

fn refuse(model: Model) -> Model {
  case model.awaiting {
    None -> model
    Some(ident) -> {
      let rows =
        list.filter_map(model.rows, fn(row) {
          case row.ident == ident, row.tag {
            True, Submitted -> Error(Nil)
            True, _ -> Ok(Row(..row, next_poll: model.now + cadence))
            False, _ -> Ok(row)
          }
        })
      Model(..model, rows:, awaiting: None)
    }
  }
}

// Which tracked rows a board lists is a bit of `listing` per position, and the
// strangers are transitions the daemon holds that this lane never saw.
fn listed(model: Model, listing: Int) -> List(Row) {
  list.index_map(model.rows, fn(row, position) {
    case int.bitwise_and(listing, int.bitwise_shift_left(1, position)) {
      0 -> Error(Nil)
      _ -> Ok(row)
    }
  })
  |> list.filter_map(fn(found) { found })
}

fn board(model: Model, listing: Int, strangers: Int) -> Model {
  let on_board = listed(model, listing)
  let kept =
    list.filter(model.rows, fn(row) { !is_settled(row.tag) })
    |> list.map(fn(row) {
      case list.contains(on_board, row), row.tag {
        True, Submitted | True, Queued | True, Running ->
          Row(..row, tag: Running)
        _, _ -> row
      }
    })

  // A request the board lists that this lane had settled, or never saw, is
  // tracked again from now: the board is the daemon's current word.
  let readopted =
    list.filter(on_board, fn(row) { is_settled(row.tag) })
    |> list.map(fn(row) {
      Row(
        ..row,
        tag: Running,
        deadline: model.now + window,
        next_poll: model.now + cadence,
      )
    })
  let fresh =
    counted(strangers)
    |> list.map(fn(k) {
      Row(
        "s" <> int.to_string(model.strangers + k),
        9,
        Running,
        model.now + window,
        model.now + cadence,
      )
    })
  let rows = list.take(list.flatten([kept, readopted, fresh]), limit)
  let awaiting = case model.awaiting {
    Some(ident) ->
      case list.any(rows, fn(row) { row.ident == ident }) {
        True -> Some(ident)
        False -> None
      }
    None -> None
  }
  Model(..model, rows:, awaiting:, strangers: model.strangers + strangers)
}

// --- the system under test ---------------------------------------------------------

// The real tracker, and the names the test gave each identity it has seen, so
// the real rows project back to the model's.
type Sut {
  Sut(tracker: pending.Tracker, names: List(#(String, String)))
}

fn violation(tag: String, detail: String) -> statem.Violation {
  statem.Violation(tag:, detail:)
}

fn candidate_id(index: Int) -> String {
  "cand" <> int.to_string(index)
}

fn candidate_index(id: String) -> Int {
  string.drop_start(id, 4) |> int.parse |> result.unwrap(-1)
}

fn ident_of(sut: Sut, request_id: String) -> String {
  case list.key_find(sut.names, request_id) {
    Ok(ident) -> ident
    Error(Nil) -> "?" <> request_id
  }
}

fn id_of(sut: Sut, ident: String) -> String {
  case list.find(sut.names, fn(pair) { pair.1 == ident }) {
    Ok(pair) -> pair.0
    Error(Nil) -> "?" <> ident
  }
}

fn tag_of(stage: pending.Stage) -> Tag {
  case stage {
    pending.Submitted -> Submitted
    pending.Staging(evolution.Queued) -> Queued
    pending.Staging(evolution.Running) | pending.Staging(..) -> Running
    pending.Publishing -> Publishing
    pending.Landed(..) -> Landed
    pending.Refused(..) -> Rejected
    pending.Vanished -> Lost
    pending.TimedOut -> TimedOut
  }
}

fn project(sut: Sut) -> #(List(Row), Option(String)) {
  let rows =
    list.map(sut.tracker.requests, fn(tracked) {
      Row(
        ident_of(sut, tracked.request_id),
        candidate_index(tracked.candidate_id),
        tag_of(tracked.stage),
        tracked.deadline_ms,
        tracked.next_poll_ms,
      )
    })
  #(rows, option.map(sut.tracker.awaiting, ident_of(sut, _)))
}

fn report_of(kind: Kind) -> evolution.Report {
  case kind {
    ReplyQueued -> evolution.InFlight(evolution.Queued)
    ReplyRunning -> evolution.InFlight(evolution.Running)
    ReplyDurable -> evolution.DurableOnly(Some(2))
    ReplyDone -> evolution.Done(Some(2))
    ReplyFailed -> evolution.Rejected("busy")
    ReplyForgotten -> evolution.Forgotten
  }
}

fn run_real(
  sut: Sut,
  model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  case command {
    Begin(candidate) ->
      case
        pending.begin(
          sut.tracker,
          session,
          model.now,
          candidate_id(candidate),
          "fmt",
        )
      {
        Error(_) -> Ok(sut)
        Ok(#(tracker, id)) ->
          case list.key_find(sut.names, id) {
            Ok(_) -> Error(violation("unique", "identity minted twice: " <> id))
            Error(Nil) ->
              Ok(
                Sut(tracker:, names: [
                  #(id, "m" <> int.to_string(tracker.minted)),
                  ..sut.names
                ]),
              )
          }
      }
    Advance(ms) -> {
      let now = model.now + ms
      let #(expired, _) = pending.expire(sut.tracker, now)
      case pending.poll(expired, now) {
        None -> Ok(Sut(..sut, tracker: expired))
        Some(#(polled, id)) -> {
          let due =
            list.find(polled.requests, fn(tracked) { tracked.request_id == id })
          case due {
            Ok(tracked) if tracked.next_poll_ms <= now ->
              Ok(Sut(..sut, tracker: polled))
            _ -> Error(violation("cadence", "polled before its time: " <> id))
          }
        }
      }
    }
    Reply(kind) ->
      Ok(
        Sut(
          ..sut,
          tracker: pending.answered(sut.tracker, report_of(kind), model.now).0,
        ),
      )
    Refuse -> Ok(Sut(..sut, tracker: pending.refused(sut.tracker, model.now)))
    Board(listing, strangers) -> {
      let on_board = listed(model, listing)
      let known =
        list.map(on_board, fn(row) {
          #(id_of(sut, row.ident), "running", candidate_id(row.candidate))
        })
      let stray =
        list.map(counted(strangers), fn(k) {
          #(
            "stranger-" <> int.to_string(model.strangers + k),
            "running",
            candidate_id(9),
          )
        })
      let names =
        list.fold(counted(strangers), sut.names, fn(names, k) {
          let number = int.to_string(model.strangers + k)
          [#("stranger-" <> number, "s" <> number), ..names]
        })
      let restored =
        pending.restore(
          sut.tracker,
          board_listing(list.append(known, stray)),
          model.now,
        )
      Ok(Sut(tracker: restored, names:))
    }
    Reconnect -> Ok(Sut(..sut, tracker: pending.reset(sut.tracker)))
  }
}

fn check_invariants(sut: Sut) -> Result(Nil, statem.Violation) {
  use <- bool_guard(
    list.length(sut.tracker.requests) > limit,
    violation("bounded", "more than sixteen requests tracked"),
  )
  case sut.tracker.awaiting {
    None -> Ok(Nil)
    Some(id) ->
      case list.find(sut.tracker.requests, fn(row) { row.request_id == id }) {
        Ok(row) ->
          case pending.settled(row.stage) {
            True -> Error(violation("awaiting", "a settled request is awaited"))
            False -> Ok(Nil)
          }
        Error(Nil) ->
          Error(violation("awaiting", "the awaited request is not tracked"))
      }
  }
}

fn bool_guard(
  broken: Bool,
  failure: statem.Violation,
  otherwise: fn() -> Result(Nil, statem.Violation),
) -> Result(Nil, statem.Violation) {
  case broken {
    True -> Error(failure)
    False -> otherwise()
  }
}

fn execute(
  sut: Sut,
  model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  let expected = predict(model, command)
  use next <- result.try(run_real(sut, model, command))
  use _ <- result.try(check_invariants(next))
  let #(rows, awaiting) = project(next)
  case rows == expected.rows && awaiting == expected.awaiting {
    True -> Ok(next)
    False ->
      Error(violation(
        "model",
        "after "
          <> string.inspect(command)
          <> " the tracker holds "
          <> string.inspect(#(rows, awaiting))
          <> " and the model expects "
          <> string.inspect(#(expected.rows, expected.awaiting)),
      ))
  }
}

// --- the commands --------------------------------------------------------------------

fn command(model: Model) -> qcheck.Generator(Command) {
  let kind =
    qcheck.bounded_int(from: 0, to: 5)
    |> qcheck.map(fn(index) {
      case index {
        0 -> ReplyQueued
        1 -> ReplyRunning
        2 -> ReplyDurable
        3 -> ReplyDone
        4 -> ReplyFailed
        _ -> ReplyForgotten
      }
    })

  // Most advances are short, so the cadence is crossed in steps, and a few
  // are long enough to cross a deadline.
  let advance =
    qcheck.from_weighted_generators(
      #(6, qcheck.bounded_int(from: 0, to: 2500)),
      [#(1, qcheck.bounded_int(from: 20_000, to: 70_000))],
    )
  let _ = model
  qcheck.from_weighted_generators(
    #(4, qcheck.map(qcheck.bounded_int(from: 0, to: 2), Begin)),
    [
      #(5, qcheck.map(advance, Advance)),
      #(6, qcheck.map(kind, Reply)),
      #(1, qcheck.return(Refuse)),
      #(
        2,
        qcheck.map2(
          qcheck.bounded_int(from: 0, to: 65_535),
          qcheck.bounded_int(from: 0, to: 2),
          Board,
        ),
      ),
      #(1, qcheck.return(Reconnect)),
    ],
  )
}

// Every command is admitted, a `Begin` while a reply is awaited included: the
// tracker refuses it itself, and the model says it changes nothing.
fn admitted(_model: Model, _command: Command) -> statem.Admission {
  statem.Admit
}

fn spec() -> statem.Spec(Model, Command, Sut) {
  statem.Spec(
    initial: start(),
    command:,
    precondition: admitted,
    next_model: predict,
    new_sut: fn() { Sut(tracker: pending.new(), names: []) },
    execute:,
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(_) { Nil },
  )
}

const runs = 300

const longest_run = 70

const seed = 20_261_023

pub fn the_tracker_keeps_its_rules_under_any_order_of_events_test() {
  let config =
    statem.default_config(seed:)
    |> statem.with_test_count(runs)
    |> statem.with_max_commands(longest_run)
  case statem.check(spec(), config) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, string.inspect)
  }
}
