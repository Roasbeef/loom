//// The shell around the ask card: reading the session's open asks, routing the
//// owner's keys to the card, and sending the answer.
////
//// `tui/ask_board` holds what the daemon said and `tui/ask_form` decides what a
//// key does. This module is where they meet the terminal's model: it starts the
//// control jobs the board asks for, files each outcome, and decides who has
//// the keyboard. It shares the terminal's one control request with the session
//// picker and the project screen, so a read starts only when the request is
//// empty and no other surface owns it, and an answer sent while another request
//// runs is refused in words with the draft kept.
////
//// ## Flow
////
//// `service` → `loaded` → `focus` → `key` → `send` → `answered`
////
//// 1. `service` runs on every tick. It starts a read when the board's rest has
////    passed and the control request is free.
//// 2. `loaded` takes the read's outcome into the board. When an ask the board
////    did not hold appears, it says so in the footer notice. It does not move
////    the keyboard.
//// 3. `focus` gives the keyboard to the card, and only the owner's key does:
////    Alt+A. Until then every key belongs to the composer, so a stray keystroke
////    cannot become an answer.
//// 4. `key` hands each key to the focused form. A checked answer reaches `send`,
////    which starts the answer job.
//// 5. `answered` takes the daemon's reply: the card disappears on success, and
////    a refusal stays on the form as words.
////
//// ## Failure
////
//// A read that finds no open ask rests the poll for `ask_board.idle_rest_ms`,
//// and one that finds an ask for `ask_board.rest_ms`. A read that fails rests
//// the poll for `ask_board.failure_rest_ms` and says nothing, because an older daemon or a saved session cannot read asks and
//// that is not an error the owner can act on. A send that fails says so, since
//// the answer may have arrived.

import core/json
import etui/keys
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/shared_set
import tui/ask_board.{type Board}
import tui/ask_form.{type Form}
import tui/job
import tui/model.{type Model, ControlRequest, Model} as tui_model
import tui/view_set
import weft

/// The words the footer shows when a new ask arrives.
const arrival_notice = "An agent asked you a question · Alt+A answers"

/// Starts the read the board is due for.
///
/// The read is a job with a connection of its own (`job.Asks`), so it never
/// holds the borrowed control request that the picker and the peer, access and
/// project screens wait on, and it runs whatever overlay is open.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.service(model)
/// ```
pub fn service(model: Model) -> Model {
  // The board belongs to the attached session; another session, or none, starts
  // over, so a saved session never shows the last session's card.
  let model = reset_for_session(model)

  // A read starts only for an attached session with a daemon connection.
  case model.view.daemon_host, model.shared.captured {
    Some(host), Some(_) -> poll(model, host)
    None, _ | Some(_), None -> model
  }
}

/// The model with the board of the session it is attached to.
fn reset_for_session(model: Model) -> Model {
  let board = ask_board.for_session(model.view.asks, model.shared.session)

  // A board of the same session is the same board. Replacing a board that
  // drew no card changes nothing a person can see, so only a card that goes
  // away repaints.
  case board == model.view.asks, ask_board.has_asks(model.view.asks) {
    True, _ -> model
    False, False -> held(model, board)
    False, True -> shown(model, board)
  }
}

/// Whether any strand of the session has a live run.
fn running(model: Model) -> Bool {
  list.any(model.shared.strands, fn(strand) { strand.live_phase != None })
}

/// Cuts the board's rest short when the last run of the session has just
/// ended, comparing the model before a step with the model after it.
///
/// An `ask` ends its asker's run, so that edge is when a new ask exists, and the
/// owner sees it at once and not within the poll's rest. The step compares two
/// models because the tick can see a run begin and end between two services.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.watch(before, after)
/// ```
pub fn watch(before: Model, after: Model) -> Model {
  // Only the edge from some strand running to none running counts.
  case running(before), running(after) {
    True, False ->
      Model(
        ..after,
        view: view_set.asks(after.view, ask_board.due(after.view.asks)),
      )
    True, True | False, True | False, False -> after
  }
}

/// Starts a read when the board's rest has passed.
fn poll(model: Model, host: job.Daemon) -> Model {
  let now = model.shared.stamp.now_ms
  let board = model.view.asks

  // A board that thinks an answer is on its way while the control request is
  // empty lost its reply, so it rests as a failed read would.
  let board = case ask_board.is_sending(board), model.view.control_request {
    True, None -> ask_board.read_failed(board, now)
    True, Some(_) | False, _ -> board
  }

  // A read starts only when the rest has passed; otherwise the board is kept.
  case ask_board.read_due(board, now) {
    True -> {
      let #(started, key) =
        tui_model.start_job(model, job.Asks(host.control, model.shared.session))

      held(started, ask_board.reading(board, job.awaiting(key)))
    }
    False -> held(model, board)
  }
}

/// Starts the answer in the control request and stores the board with the
/// send recorded, so the board knows what the request holds.
fn start_send(
  model: Model,
  host: job.Daemon,
  board: Board,
  request: job.ControlJob,
  ask: String,
) -> Model {
  let #(started, key) =
    tui_model.start_job(model, job.Control(host.control, request))

  Model(
    ..started,
    view: started.view
      |> view_set.asks(ask_board.sending(board, ask))
      |> view_set.control_request(Some(ControlRequest(job.awaiting(key), None))),
  )
}

/// Stores the board without a repaint, for a change nobody can see.
fn held(model: Model, board: Board) -> Model {
  Model(..model, view: view_set.asks(model.view, board))
}

/// Stores the board and repaints.
fn shown(model: Model, board: Board) -> Model {
  Model(..model, view: view_set.asks(model.view, board))
  |> tui_model.invalidate_frame
}

// --- outcomes ---------------------------------------------------------------

/// Takes the read job's next reply, if the runtime has admitted one.
///
/// A completed read is filed into the board. A failed or lost one rests the
/// poll and says nothing, and the board keeps what it drew.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.drain(model)
/// ```
pub fn drain(model: Model) -> Model {
  // Only a board with a read running has a reply to take.
  case model.view.asks.phase {
    ask_board.Reading(job: awaiting) ->
      case job.take(awaiting) {
        #(_, Error(Nil)) -> model
        #(awaiting, Ok(reply)) ->
          applied(
            held(
              model,
              ask_board.Board(
                ..model.view.asks,
                phase: ask_board.Reading(awaiting),
              ),
            ),
            reply,
          )
      }
    ask_board.ReadDue | ask_board.Resting(..) | ask_board.Sending(..) -> model
  }
}

/// Applies one reply of the read job.
fn applied(model: Model, reply: job.AsksReply) -> Model {
  // Only a completed read carries asks; every other end rests the poll.
  case reply {
    weft.PulledOutcome(weft.Completed(value:, ..)) ->
      loaded(model, value.session, value.count, value.records)
    weft.NotYet -> model
    weft.PulledOutcome(_) | weft.AllDelivered | weft.RunLost(_) ->
      held(
        model,
        ask_board.read_failed(model.view.asks, model.shared.stamp.now_ms),
      )
  }
}

/// Files a finished read into the board. A read for a session the terminal has
/// since left changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.loaded(model, "0198c0de-...", 0, [])
/// ```
pub fn loaded(
  model: Model,
  session: String,
  count: Int,
  records: List(json.JsonValue),
) -> Model {
  let board = ask_board.for_session(model.view.asks, model.shared.session)

  // The board belongs to the attached session; an answer to the previous one
  // has nothing to land on.
  case session == model.shared.session {
    False -> held(model, board)
    True -> {
      let next =
        ask_board.loaded(board, count, records, model.shared.stamp.now_ms)

      // A card whose content did not change is not repainted.
      case next.forms == board.forms && next.open == board.open {
        True -> held(model, next)
        False -> announced(shown(model, next), board, next)
      }
    }
  }
}

/// Tells the owner when an ask appeared that the board had not drawn. The
/// notice is the footer's, so it does not move the keyboard.
fn announced(model: Model, before: Board, after: Board) -> Model {
  let fresh =
    list.any(after.forms, fn(form) {
      form.standing == ask_form.MayAnswer
      && !list.any(before.forms, fn(held) {
        held.ask.header.id == form.ask.header.id
      })
    })

  // The notice is the footer's, so saying it never moves the keyboard.
  case fresh {
    True ->
      Model(..model, shared: shared_set.notice(model.shared, arrival_notice))
    False -> model
  }
}

/// Files the daemon's reply to an answer: the ask is gone when it was accepted,
/// and a refusal stays on the form in words.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.answered(model, "0198c0de-...", "ask-3f9c01a2b4", Ok("admitted"))
/// ```
pub fn answered(
  model: Model,
  session: String,
  ask: String,
  delivery: Result(String, job.AskRefusal),
) -> Model {
  let board = ask_board.for_session(model.view.asks, model.shared.session)

  // The reply names the session it was sent for; another session's board has
  // no such ask.
  case session == model.shared.session, delivery {
    False, _ -> held(model, board)
    True, Ok(way) -> {
      let words = delivery_words(way)
      shown(
        Model(..model, shared: shared_set.notice(model.shared, words)),
        ask_board.answered(board, ask),
      )
    }
    True, Error(refusal) ->
      shown(model, ask_board.answer_refused(board, ask, refusal_words(refusal)))
  }
}

/// The words for an accepted answer, by how the strand took the prompt.
///
/// ## Examples
///
/// ```gleam
/// assert ask_control.delivery_words("queued")
///   == "Answer sent · queued behind the agent's current turn"
/// ```
pub fn delivery_words(way: String) -> String {
  case way {
    "queued" -> "Answer sent · queued behind the agent's current turn"
    "admitted" -> "Answer sent · the agent is continuing"
    _ -> "Answer sent"
  }
}

/// The words for a refused answer, from the daemon's code and message. The
/// message names the first failing key for `bad_request`, which reads as the
/// question's number.
///
/// ## Examples
///
/// ```gleam
/// assert ask_control.refusal_words(job.AskRefusal("forbidden", ""))
///   == "You hold this session as an observer, so you cannot answer."
/// ```
pub fn refusal_words(refusal: job.AskRefusal) -> String {
  case refusal.code {
    "conflict" ->
      case string.contains(refusal.message, "delivered") {
        True ->
          "The answer was delivered, but the ask changed. Reading it again."
        False ->
          "The ask changed or was answered elsewhere. Reading it again; check your answer and send it again."
      }
    "bad_request" -> "The daemon refused the answer: " <> asked(refusal.message)
    "forbidden" -> "You hold this session as an observer, so you cannot answer."
    "not_found" ->
      "The ask is gone: it was answered, or this session no longer holds it."
    "not_resident" -> "The session is not running, so it cannot take an answer."
    "unavailable" ->
      "The daemon did not confirm delivery in time. The answer may have arrived; reading the ask again."
    "stale_epoch" ->
      "The daemon restarted since this terminal connected. Reconnect with /sessions and answer again."
    code -> "The daemon refused the answer (" <> code <> ")."
  }
}

/// A `bad_request` message, `q2: not one of the options`, as a question's
/// number and the daemon's words.
fn asked(message: String) -> String {
  case string.split_once(message, ": ") {
    Ok(#(key, words)) -> ask_form.problem_words(ask_form.Problem(key, words))
    Error(Nil) -> message
  }
}

/// Files a failed control job that held the board's request.
///
/// A failed read rests the poll and says nothing. A failed send says so, and
/// shows the same on the card, because the answer may have arrived.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.failed(model, "daemon control timed out")
/// ```
pub fn failed(model: Model, reason: String) -> Model {
  let board = model.view.asks
  let now = model.shared.stamp.now_ms

  // Only a send fails into the control request. It may have delivered, so the
  // owner is told and the ask is read again.
  case board.phase {
    ask_board.Sending(ask:) ->
      shown(
        tui_model.append_error(
          model,
          "The answer to " <> ask <> " may not have been sent: " <> reason,
        ),
        ask_board.answer_refused(
          board,
          ask,
          "The daemon did not answer: "
            <> reason
            <> ". The answer may have arrived; reading the ask again.",
        ),
      )
    ask_board.Reading(..) | ask_board.ReadDue | ask_board.Resting(..) ->
      held(model, ask_board.read_failed(board, now))
  }
}

/// Whether the board's request is the one in the control request, which is how
/// a failed job is told to belong to the asks and not to another surface.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.owns_request(model)
/// ```
pub fn owns_request(model: Model) -> Bool {
  ask_board.is_sending(model.view.asks)
}

// --- keys -------------------------------------------------------------------

/// Whether an open ask can be answered from here: the daemon says the owner
/// may answer it.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.answerable(model)
/// ```
pub fn answerable(model: Model) -> Bool {
  list.any(model.view.asks.forms, fn(form) {
    form.standing == ask_form.MayAnswer
  })
}

/// Whether the card has the keyboard.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.has_keyboard(model)
/// ```
pub fn has_keyboard(model: Model) -> Bool {
  ask_board.focused(model.view.asks) != None
}

/// Gives the keyboard to the first ask the owner can answer. Nothing but the
/// owner's key reaches here, so an ask arriving never takes the composer's
/// keystrokes.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.focus(model)
/// ```
pub fn focus(model: Model) -> Model {
  shown(model, ask_board.focus_card(model.view.asks))
}

/// Routes one key to the form that has the keyboard.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.key(model, keys.Down)
/// ```
pub fn key(model: Model, key: keys.Key) -> Model {
  case ask_board.focused(model.view.asks) {
    None -> model
    Some(#(index, form)) -> acted(model, index, ask_form.update(key, form))
  }
}

/// Routes pasted text to the form that has the keyboard.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.pasted(model, "main")
/// ```
pub fn pasted(model: Model, text: String) -> Model {
  case ask_board.focused(model.view.asks) {
    None -> model
    Some(#(index, form)) ->
      shown(
        model,
        ask_board.with_form(model.view.asks, index, ask_form.pasted(form, text)),
      )
  }
}

/// Carries out what a key asked of the form at `index`.
fn acted(model: Model, index: Int, action: ask_form.Action) -> Model {
  let board = model.view.asks

  // Each action either changes the board or sends an answer.
  case action {
    ask_form.Continue(form:) ->
      shown(model, ask_board.with_form(board, index, form))
    ask_form.Leave(form:) ->
      shown(model, ask_board.leave(ask_board.with_form(board, index, form)))
    ask_form.Page(form:, by:) ->
      shown(model, ask_board.cycle(ask_board.with_form(board, index, form), by))
    ask_form.Send(form:, answer:) -> send(model, index, form, answer)
  }
}

/// Sends a checked answer when the control request is free. A busy request
/// keeps the draft and says to try again, because dropping an answer silently
/// would lose the owner's text.
fn send(model: Model, index: Int, form: Form, answer: json.JsonValue) -> Model {
  let board = ask_board.with_form(model.view.asks, index, form)

  // The answer goes only when a daemon connection exists and nothing else
  // holds the control request.
  case
    model.view.daemon_host,
    model.view.control_request,
    ask_board.is_sending(board)
  {
    Some(host), None, False ->
      start_send(
        model,
        host,
        board,
        job.AnswerAsk(
          model.shared.session,
          form.ask.header.id,
          form.revision,
          answer,
        ),
        form.ask.header.id,
      )
      |> tui_model.invalidate_frame
    None, _, _ ->
      refused(
        model,
        board,
        index,
        form,
        "Daemon control is unavailable, so the answer cannot be sent.",
      )
    Some(_), Some(_), _ | Some(_), None, True ->
      refused(
        model,
        board,
        index,
        form,
        "Another daemon request is running. Try again in a moment.",
      )
  }
}

/// Shows `words` on the form and keeps the draft.
fn refused(
  model: Model,
  board: Board,
  index: Int,
  form: Form,
  words: String,
) -> Model {
  shown(model, ask_board.with_form(board, index, ask_form.refused(form, words)))
}

/// The footer notice and the answered words, for a caller that has neither.
///
/// ## Examples
///
/// ```gleam
/// assert ask_control.arrival() == "An agent asked you a question · Alt+A answers"
/// ```
pub fn arrival() -> String {
  arrival_notice
}

/// The card's first answerable form, for a test that needs to read it.
///
/// ## Examples
///
/// ```gleam
/// // ask_control.focused_form(model)
/// ```
pub fn focused_form(model: Model) -> Option(Form) {
  ask_board.focused(model.view.asks)
  |> option.map(fn(entry) { entry.1 })
}
