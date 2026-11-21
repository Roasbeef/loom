//// The ticket thread's rule (`web_view/ticket_rule`): which tickets are
//// threads, which controls the daemon's list leaves, what one confirm click
//// guards, and the words of an act's outcome.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/project_board as board
import web_view/projects.{Acted, Declined}
import web_view/ticket_rule.{
  Answer, Asked, Close, Confirming, Nothing, Operating, Resting, Retry, Send,
  Sending, Stop, Unasked, Watching,
}

fn ticket(
  id: String,
  stage: board.Stage,
  actions: List(board.Action),
) -> board.Ticket {
  board.Ticket(
    id:,
    title: Some("title of " <> id),
    stage:,
    session: None,
    mandate: None,
    opened_ms: Some(1000),
    question: Some(board.Question(seq: 7, text: "which database?", options: [])),
    pull_request: None,
    failure: None,
    check: None,
    actions:,
  )
}

fn board_of(tickets: List(board.Ticket)) -> projects.Loaded {
  projects.Loaded(
    id: "p1",
    workspace: "/src/loom",
    board: Some(
      board.Board(
        project: "p1",
        revision: 3,
        total: list.length(tickets),
        tickets:,
        unreadable: 0,
        would: [],
        rules: [],
        notes: [],
      ),
    ),
  )
}

fn key() -> ticket_rule.Key {
  ticket_rule.Key(project: "p1", ticket: "t-a")
}

// Only a ticket whose stage needs a person is a thread, and a stage this
// client has never heard of is one when the daemon spelled it `person/...`.
pub fn only_tickets_waiting_on_a_person_are_threads_test() {
  let held = [
    board_of([
      ticket("t-work", board.Working, []),
      ticket("t-ask", board.PersonAnswer, []),
      ticket("t-check", board.PersonCheck, []),
      ticket("t-odd", board.UnknownStage("triage"), []),
    ]),
  ]

  let ids =
    ticket_rule.waiting(held)
    |> list.map(fn(each) { each.key.ticket })
  assert ids == ["t-ask", "t-check"]
}

// The controls are exactly the actions the daemon listed, whatever the stage:
// a `person/check` ticket draws what its list says and nothing derived from its
// word, and an action this client does not know draws nothing.
pub fn controls_follow_the_daemons_list_and_never_the_stage_test() {
  let listed =
    ticket("t-check", board.PersonCheck, [
      board.CanClose,
      board.CanStop,
      board.UnknownAction("recheck"),
    ])
  assert ticket_rule.controls(listed, Operating) == [Close, Stop]

  // The same stage with a different list draws a different set.
  let other =
    ticket("t-check", board.PersonCheck, [
      board.CanRetry,
    ])
  assert ticket_rule.controls(other, Operating) == [Retry]

  // A known stage with an empty list draws none.
  let none = ticket("t-ask", board.PersonAnswer, [])
  assert ticket_rule.controls(none, Operating) == []
}

// Answer carries the question's number and needs the question; the order is
// fixed; and Publish has no control, because the board carries no reason for a
// publish that is listed and not allowed.
pub fn answer_needs_its_question_and_publish_draws_nothing_test() {
  let all =
    ticket("t-a", board.PersonAnswer, [
      board.CanStop,
      board.CanPublish,
      board.CanRetry,
      board.CanClose,
      board.CanAnswer,
    ])
  assert ticket_rule.controls(all, Operating) == [Answer(7), Close, Retry, Stop]

  let no_question = board.Ticket(..all, question: None)
  assert ticket_rule.controls(no_question, Operating) == [Close, Retry, Stop]
}

// An observing page has the thread and no control, and a press that names a
// control the list does not hold is not allowed.
pub fn a_watching_page_has_no_controls_and_unlisted_presses_are_refused_test() {
  let held = ticket("t-a", board.PersonAnswer, [board.CanAnswer, board.CanStop])
  assert ticket_rule.controls(held, Watching) == []
  assert ticket_rule.allowed(held, Operating, Stop)
  assert !ticket_rule.allowed(held, Watching, Stop)
  assert !ticket_rule.allowed(held, Operating, Close)

  // An answer to a question that is not the open one is not the control drawn.
  assert ticket_rule.allowed(held, Operating, Answer(7))
  assert !ticket_rule.allowed(held, Operating, Answer(8))
}

// Stop and Close ask first. The confirmation sends exactly what was asked,
// "Keep" takes it back, and pressing the other of the two replaces the
// question.
pub fn stop_and_close_need_one_confirm_click_test() {
  let opened = ticket_rule.open(key())

  let assert Confirming(asked) = ticket_rule.press(opened, Stop)
  assert asked.confirm == Asked(Stop)
  assert asked.progress == Resting

  let assert Confirming(replaced) = ticket_rule.press(asked, Close)
  assert replaced.confirm == Asked(Close)

  let assert Send(out, Close) = ticket_rule.confirmed(replaced)
  assert out.progress == Sending
  assert out.confirm == Unasked

  assert ticket_rule.cancelled(asked).confirm == Unasked
  assert ticket_rule.confirmed(ticket_rule.cancelled(asked)) == Nothing
}

// Retry and Answer are sent at once, and nothing is sent while an act is out.
pub fn retry_and_answer_send_at_once_and_one_act_is_out_at_a_time_test() {
  let opened = ticket_rule.open(key())

  let assert Send(out, Retry) = ticket_rule.press(opened, Retry)
  assert out.progress == Sending
  assert ticket_rule.press(out, Retry) == Nothing
  assert ticket_rule.press(out, Stop) == Nothing
  assert ticket_rule.confirmed(out) == Nothing

  let assert Send(_, Answer(7)) = ticket_rule.press(opened, Answer(7))
}

// The daemon's word makes the pane ready again either way. A recorded answer
// empties the box by moving its key, and a refusal leaves it as typed.
pub fn the_daemons_word_becomes_the_panes_notice_test() {
  let assert Send(out, Close) =
    ticket_rule.confirmed(
      ticket_rule.Opened(..ticket_rule.open(key()), confirm: Asked(Close)),
    )

  let closed = ticket_rule.settled(out, Close, Acted)
  assert closed.progress == Resting
  assert closed.notice == Some(ticket_rule.Told("Ticket closed."))

  let answered = ticket_rule.settled(out, Answer(7), Acted)
  assert answered.answered == 1
  let refused = ticket_rule.settled(out, Answer(7), Declined("conflict"))
  assert refused.answered == 0
  assert refused.notice
    == Some(ticket_rule.Refused(board.answer_refusal_words("conflict")))
  assert refused.progress == Resting
}

// A code the client has no sentence for is made safe, so a control character in
// the daemon's text cannot reach the page.
pub fn refusal_words_are_the_daemons_code_made_safe_test() {
  assert ticket_rule.refusal_words(Stop, "bad_request")
    == "That ticket cannot be stopped: it has ended or was already stopped."
  assert ticket_rule.refusal_words(Retry, "forbidden")
    == "Only the owner can retry a project's ticket."
  assert !string.contains(
    ticket_rule.refusal_words(Stop, "odd\u{1b}[31m code"),
    "\u{1b}",
  )
}

// A thread reads the ticket again only when it holds no read or its project's
// board has moved past the read it holds.
pub fn a_thread_is_stale_when_the_board_moved_past_its_read_test() {
  let held = [board_of([ticket("t-a", board.PersonAnswer, [])])]
  let opened = ticket_rule.open(key())
  assert ticket_rule.stale(opened, held)

  let read =
    board.Detail(
      project: "p1",
      revision: 3,
      ticket: ticket("t-a", board.PersonAnswer, []),
      assignments: [],
      inputs: [],
    )
  let current = ticket_rule.heard(opened, read)
  assert !ticket_rule.stale(current, held)
  assert ticket_rule.stale(
    ticket_rule.heard(opened, board.Detail(..read, revision: 2)),
    held,
  )
}

// A confirmation for an act the ticket no longer offers is dropped by a read,
// and one it still offers is kept.
pub fn a_read_drops_a_confirmation_the_list_no_longer_holds_test() {
  let opened =
    ticket_rule.Opened(..ticket_rule.open(key()), confirm: Asked(Stop))
  let offered = ticket("t-a", board.PersonAnswer, [board.CanStop])
  let withdrawn = ticket("t-a", board.PersonAnswer, [board.CanClose])
  let read = fn(held) {
    board.Detail(
      project: "p1",
      revision: 4,
      ticket: held,
      assignments: [],
      inputs: [],
    )
  }

  let kept = ticket_rule.heard(opened, read(offered))
  assert ticket_rule.reconciled(kept, Operating).confirm == Asked(Stop)

  let dropped = ticket_rule.heard(opened, read(withdrawn))
  assert ticket_rule.reconciled(dropped, Operating).confirm == Unasked

  // A page that may not operate keeps no confirmation either.
  assert ticket_rule.reconciled(kept, Watching).confirm == Unasked
}

// Silence from the project is worded as "read again", for every act, and is
// never the words of a refusal.
pub fn an_unanswered_act_says_to_read_again_test() {
  let words = ticket_rule.unanswered_words

  assert ticket_rule.refusal_words(Stop, "unanswered") == words
  assert ticket_rule.refusal_words(Retry, "unanswered") == words
  assert ticket_rule.refusal_words(Close, "unanswered") == words
  assert ticket_rule.refusal_words(Answer(7), "unanswered") == words
  assert string.contains(words, "Reread the ticket")
}
