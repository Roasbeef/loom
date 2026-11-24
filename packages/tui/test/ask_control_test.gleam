//// The ask card's shell: when it reads, who has the keyboard, what sending
//// does, and how the daemon's replies and refusals are filed.
////
//// The driver tests run the shipped `tui.step` with a control connection
//// adopted, as the project screen's tests do, so the tick's read, the job it
//// starts and the key routing are the real ones.

import ask_scene
import core/attention
import core/json
import etui/backend
import etui/widgets/textarea
import frame_scene
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/model as session_model
import session_view/protocol
import session_view/shared_set
import tui/ask_board
import tui/ask_control
import tui/ask_form
import tui/daemon/selection as daemon_selection
import tui/effect
import tui/job
import tui/model as tui_model
import tui/runtime
import tui/session_control
import tui_test/stepping
import weft

@external(erlang, "effects_test_ffi", "host_on")
fn host_on(owner: Subject(Dynamic)) -> daemon_selection.Host

// An attached scene with a control connection, so the tick may read.
fn connected() -> tui_model.Model {
  let inbox: Subject(Dynamic) = process.new_subject()
  runtime.adopt_control(ask_scene.with_asks([], 0), host_on(inbox))
}

fn with_form(model: tui_model.Model, form: ask_form.Form) -> tui_model.Model {
  tui_model.Model(
    ..model,
    view: tui_model.View(
      ..model.view,
      asks: ask_board.Board(
        ..model.view.asks,
        forms: [form],
        open: 1,
        phase: ask_board.Resting(1_000_000),
      ),
    ),
  )
}

fn the_form() -> ask_form.Form {
  ask_scene.form(ask_scene.choice_ask(
    "ask-3f9c01a2b4",
    ask_scene.thirteen_forty,
  ))
}

fn press(model: tui_model.Model, key: String) -> tui_model.Model {
  stepping.step(backend.KeyPress(key), model).0
}

fn pressing(model: tui_model.Model, pressed: List(String)) -> tui_model.Model {
  list.fold(pressed, model, press)
}

fn jobs(effects: List(effect.Effect)) -> List(job.Spec) {
  list.filter_map(effects, fn(requested) {
    case requested {
      effect.StartJob(_, spec) -> Ok(spec)
      _ -> Error(Nil)
    }
  })
}

fn composer(model: tui_model.Model) -> String {
  textarea.value(model.view.input)
}

// Hands the control slot's job an outcome and the relay's end, and drains both.
fn deliver(
  model: tui_model.Model,
  outcome: job.ControlOutcome,
) -> tui_model.Model {
  let assert Some(tui_model.ControlRequest(job: awaiting, ..)) =
    model.view.control_request
  let key = job.key(awaiting)

  model
  |> runtime.hold(job.ControlArrived(
    key,
    weft.PulledOutcome(weft.Completed(0, outcome)),
  ))
  |> runtime.hold(job.ControlArrived(key, weft.AllDelivered))
  |> session_control.drain_control
  |> session_control.drain_control
}

fn fail(model: tui_model.Model, reason: String) -> tui_model.Model {
  let assert Some(tui_model.ControlRequest(job: awaiting, ..)) =
    model.view.control_request
  let key = job.key(awaiting)

  model
  |> runtime.hold(job.ControlArrived(
    key,
    weft.PulledOutcome(weft.Failed(0, reason)),
  ))
  |> runtime.hold(job.ControlArrived(key, weft.AllDelivered))
  |> session_control.drain_control
  |> session_control.drain_control
}

// Hands the read job a completed reply and the relay's end, and drains them.
fn deliver_read(model: tui_model.Model, read: job.AsksRead) -> tui_model.Model {
  let assert ask_board.Reading(job: awaiting) = model.view.asks.phase
  let key = job.key(awaiting)

  model
  |> runtime.hold(job.AsksArrived(
    key,
    weft.PulledOutcome(weft.Completed(0, read)),
  ))
  |> runtime.hold(job.AsksArrived(key, weft.AllDelivered))
  |> ask_control.drain
}

// Hands the read job a failure and the relay's end, and drains them.
fn fail_read(model: tui_model.Model, reason: String) -> tui_model.Model {
  let assert ask_board.Reading(job: awaiting) = model.view.asks.phase
  let key = job.key(awaiting)

  model
  |> runtime.hold(job.AsksArrived(
    key,
    weft.PulledOutcome(weft.Failed(0, reason)),
  ))
  |> runtime.hold(job.AsksArrived(key, weft.AllDelivered))
  |> ask_control.drain
}

pub fn the_tick_reads_the_attached_sessions_asks_on_a_connection_of_its_own_test() {
  let #(ticked, effects) = stepping.step(backend.Tick, connected())
  assert jobs(effects)
    |> list.any(fn(spec) {
      case spec {
        job.Asks(_, session) -> session == ask_scene.session
        _ -> False
      }
    })
  assert ask_board.in_flight(ticked.view.asks)
  assert ticked.view.control_request == None
    as "a poll never holds the borrowed control request"

  // Nothing more is asked while the read is running.
  let #(_, again) = stepping.step(backend.Tick, ticked)
  assert jobs(again) == []
}

pub fn a_terminal_with_no_daemon_connection_reads_nothing_test() {
  let #(_, effects) = stepping.step(backend.Tick, ask_scene.with_asks([], 0))
  assert jobs(effects) == []
}

pub fn a_loaded_read_draws_the_ask_and_says_so_without_moving_the_keyboard_test() {
  let #(reading, _) = stepping.step(backend.Tick, connected())
  let document = ask_board_document(the_form().ask, 41, True)
  let loaded =
    deliver_read(reading, job.AsksRead(ask_scene.session, 1, [document]))
  assert list.length(loaded.view.asks.forms) == 1
  assert loaded.view.asks.focus == ask_board.Composer
  assert loaded.shared.notice == ask_control.arrival()
  assert loaded.view.control_request == None
}

// The reply of `attention.read`, as the daemon words it.
fn ask_board_document(
  ask: attention.Ask,
  revision: Int,
  may_answer: Bool,
) -> json.JsonValue {
  let assert json.Object(stored) = attention.encode_ask(ask)
  let assert Ok(json.Object(content)) = list.key_find(stored, "content")
  json.Object(
    list.flatten([
      list.filter(stored, fn(field) {
        field.0 != "content" && field.0 != "parents"
      }),
      content,
      [
        #("revision", json.Int(revision)),
        #("may_answer", json.Bool(may_answer)),
      ],
    ]),
  )
}

pub fn an_ask_appearing_never_turns_composer_keys_into_answers_test() {
  let model = with_form(connected(), the_form())

  // Typing, a space, Enter on an empty composer: all of it is the composer's.
  let typed = pressing(model, ["h", "i", " ", "j"])
  assert composer(typed) == "hi j"
  assert typed.view.asks.forms == model.view.asks.forms
  assert typed.view.asks.focus == ask_board.Composer
}

pub fn alt_a_gives_the_ask_the_keyboard_and_escape_gives_it_back_test() {
  let model = with_form(connected(), the_form())
  let focused = press(model, "alt+a")
  assert focused.view.asks.focus == ask_board.Card("ask-3f9c01a2b4")

  // Keys now move the ask's cursor and the composer stays empty.
  let moved = pressing(focused, ["down", "x", "y"])
  assert composer(moved) == ""
  let assert Some(form) = ask_control.focused_form(moved)
  assert form.cursor == 1

  let back = press(moved, "esc")
  assert back.view.asks.focus == ask_board.Composer
  let assert [kept] = back.view.asks.forms
  assert kept.cursor == 1
  assert composer(pressing(back, ["z"])) == "z"
}

pub fn alt_a_with_no_ask_to_answer_does_nothing_to_the_asks_test() {
  let none = press(connected(), "alt+a")
  assert none.view.asks.focus == ask_board.Composer

  let observer =
    with_form(
      connected(),
      ask_form.Form(..the_form(), standing: ask_form.ObserverOnly),
    )
  assert press(observer, "alt+a").view.asks.focus == ask_board.Composer
}

pub fn a_checked_answer_starts_the_answer_job_with_the_revision_read_test() {
  let model = with_form(connected(), the_form())
  let answered = pressing(model, ["alt+a", " ", "tab", "enter"])
  let #(sent, effects) = stepping.step(backend.KeyPress("ctrl+s"), answered)
  let values = [
    #("q1", attention.Picked("Fold under open ones")),
    #("q2", attention.Yes),
  ]
  assert jobs(effects)
    |> list.any(fn(spec) {
      case spec {
        job.Control(_, job.AnswerAsk(session:, ask:, revision:, answer:)) ->
          session == ask_scene.session
          && ask == "ask-3f9c01a2b4"
          && revision == 41
          && answer == attention.answer_object(values)
        _ -> False
      }
    })
  assert sent.view.asks.phase == ask_board.Sending("ask-3f9c01a2b4")
}

pub fn an_incomplete_answer_sends_nothing_and_says_why_test() {
  let model = with_form(connected(), the_form())
  let #(refused, effects) =
    stepping.step(backend.KeyPress("ctrl+s"), press(model, "alt+a"))
  assert jobs(effects) == []
  let assert Some(form) = ask_control.focused_form(refused)
  assert form.refusal == Some("Question 1: needs an answer")
}

pub fn a_busy_control_request_keeps_the_draft_and_sends_nothing_test() {
  // The picker's page read holds the borrowed control request.
  let #(busy, _) = stepping.step(backend.KeyPress("left"), connected())
  assert option.is_some(busy.view.control_request)
  let model = with_form(busy, the_form())
  let ready = pressing(model, ["alt+a", " ", "tab", "enter"])
  let #(held, effects) = stepping.step(backend.KeyPress("ctrl+s"), ready)
  assert jobs(effects) == []
  let assert Some(form) = ask_control.focused_form(held)
  assert form.refusal
    == Some("Another daemon request is running. Try again in a moment.")
  assert ask_form.values(form) != []
}

pub fn an_accepted_answer_removes_the_card_and_tells_the_owner_test() {
  let model = with_form(connected(), the_form())
  let ready = pressing(model, ["alt+a", " ", "tab", "enter", "ctrl+s"])
  let done =
    deliver(
      ready,
      job.AskAnswered(ask_scene.session, "ask-3f9c01a2b4", Ok("queued")),
    )
  assert done.view.asks.forms == []
  assert done.view.asks.focus == ask_board.Composer
  assert done.view.asks.phase == ask_board.ReadDue
  assert done.shared.notice
    == "Answer sent · queued behind the agent's current turn"
}

pub fn a_refused_answer_keeps_the_card_with_the_daemons_words_test() {
  let model = with_form(connected(), the_form())
  let ready = pressing(model, ["alt+a", " ", "tab", "enter", "ctrl+s"])
  let refused =
    deliver(
      ready,
      job.AskAnswered(
        ask_scene.session,
        "ask-3f9c01a2b4",
        Error(job.AskRefusal("conflict", "revision moved")),
      ),
    )
  let assert [form] = refused.view.asks.forms
  assert form.refusal
    == Some(
      "The ask changed or was answered elsewhere. Reading it again; check your answer and send it again.",
    )
  assert ask_form.values(form) != []
  assert refused.view.asks.phase == ask_board.ReadDue
}

pub fn a_failed_read_rests_quietly_and_a_failed_send_says_so_test() {
  let #(reading, _) = stepping.step(backend.Tick, connected())
  let failed = fail_read(reading, "daemon control timed out")
  assert failed.view.asks.phase
    == ask_board.Resting(failed.shared.stamp.now_ms + ask_board.failure_rest_ms)
  assert failed.shared.notice == reading.shared.notice

  let model = with_form(connected(), the_form())
  let ready = pressing(model, ["alt+a", " ", "tab", "enter", "ctrl+s"])
  let lost = fail(ready, "daemon control timed out")
  let assert [form] = lost.view.asks.forms
  assert option.is_some(form.refusal)
  assert string.contains(
    option.unwrap(form.refusal, ""),
    "The answer may have arrived",
  )
}

pub fn the_daemons_refusals_are_worded_test() {
  assert ask_control.refusal_words(job.AskRefusal("forbidden", ""))
    == "You hold this session as an observer, so you cannot answer."
  assert ask_control.refusal_words(job.AskRefusal(
      "bad_request",
      "q2: not one of the options",
    ))
    == "The daemon refused the answer: Question 2: not one of the options"
  assert ask_control.refusal_words(job.AskRefusal(
      "conflict",
      "delivered; the record changed",
    ))
    == "The answer was delivered, but the ask changed. Reading it again."
  assert ask_control.refusal_words(job.AskRefusal("not_found", ""))
    == "The ask is gone: it was answered, or this session no longer holds it."
  assert ask_control.refusal_words(job.AskRefusal("something_new", ""))
    == "The daemon refused the answer (something_new)."
  assert ask_control.delivery_words("admitted")
    == "Answer sent · the agent is continuing"
}

pub fn a_read_for_a_session_the_terminal_left_changes_nothing_test() {
  let model = with_form(connected(), the_form())
  let due =
    tui_model.Model(
      ..model,
      view: tui_model.View(
        ..model.view,
        asks: ask_board.Board(..model.view.asks, phase: ask_board.ReadDue),
      ),
    )
  let #(reading, _) = stepping.step(backend.Tick, due)
  let loaded = deliver_read(reading, job.AsksRead("another-session", 0, []))
  assert loaded.view.asks.forms == model.view.asks.forms
  let _ = frame_scene.model
  let _ = shared_set.notice
}

// A run that ended is when an ask exists, so the poll's rest is cut short.
pub fn the_last_run_ending_cuts_the_polls_rest_short_test() {
  let model = with_form(connected(), the_form())
  let running =
    tui_model.Model(
      ..model,
      shared: shared_set.strands(model.shared, [
        protocol.Strand("main", None, Some("generating")),
      ]),
    )
  let idle =
    tui_model.Model(
      ..model,
      shared: shared_set.strands(model.shared, [
        protocol.Strand("main", None, None),
      ]),
    )

  // The edge from running to idle makes a read due.
  assert ask_control.watch(running, idle).view.asks.phase == ask_board.ReadDue

  // Neither staying idle nor starting a run does.
  assert ask_control.watch(idle, idle).view.asks.phase == model.view.asks.phase
  assert ask_control.watch(idle, running).view.asks.phase
    == model.view.asks.phase
}

// A poll never waits for the borrowed control request, and never holds it, so
// the picker and the peer and access screens are not refused while it runs.
pub fn a_read_starts_while_another_control_request_runs_test() {
  let #(busy, _) = stepping.step(backend.KeyPress("left"), connected())
  assert option.is_some(busy.view.control_request)
  let #(ticked, effects) = stepping.step(backend.Tick, busy)
  assert list.any(jobs(effects), fn(spec) {
    case spec {
      job.Asks(..) -> True
      _ -> False
    }
  })
  assert ticked.view.control_request == busy.view.control_request
}

// A saved session is not shown the last session's card.
pub fn a_change_of_session_clears_the_card_before_anything_else_is_asked_test() {
  let model = with_form(connected(), the_form())
  assert model.view.asks.forms != []
  let elsewhere =
    tui_model.Model(
      ..model,
      shared: session_model.Shared(..model.shared, session: "another-session"),
    )
  let ticked = ask_control.service(elsewhere)
  assert ticked.view.asks.forms == []
  assert ticked.view.asks.session == "another-session"
}

// A read that lands after the terminal attached elsewhere drops its asks, and
// the card the board still drew for the old session is repainted away.
pub fn a_read_for_a_left_session_clears_the_stale_card_with_a_repaint_test() {
  let model = with_form(connected(), the_form())
  let due =
    tui_model.Model(
      ..model,
      view: tui_model.View(
        ..model.view,
        asks: ask_board.Board(..model.view.asks, phase: ask_board.ReadDue),
      ),
    )
  let #(reading, _) = stepping.step(backend.Tick, due)
  let moved =
    tui_model.Model(
      ..reading,
      shared: session_model.Shared(..reading.shared, session: "another-session"),
    )
  let loaded = deliver_read(moved, job.AsksRead(ask_scene.session, 1, []))
  assert loaded.view.asks.forms == []
  assert loaded.view.asks.session == "another-session"
  assert loaded.shared.frame_revision == moved.shared.frame_revision + 1
}
