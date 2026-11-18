//// What the inbox sends to a session and what its outbox says
//// (`web_view/thread_send`, protocol-change/118).
////
//// These tests pin the closed vocabulary around one message: which buttons
//// each kind of thread offers, which delivery each button is, which drafts may
//// be sent, and the fixed words of each answer. The words are checked to
//// carry nothing the session or the gateway wrote, over generated reasons with
//// a fixed seed.

import gleam/option.{None, Some}
import gleam/string
import qcheck
import session_view/operator
import web_view/inbox_rule
import web_view/thread_send.{
  Admitted, Delivered, NotAccepted, NotHeld, NotResident, QueueFull, Queued,
  Refused, Unanswered,
}

const seed = 20_261_118

// A session that is idle, failed or settled takes one Send. A working one takes
// a Queue and a Steer, and one waiting on an approval takes a Queue alone, with
// the words that say what it waits behind.
pub fn each_state_offers_the_buttons_that_make_sense_test() {
  assert thread_send.choices(inbox_rule.Idle) == [thread_send.Send]
  assert thread_send.choices(inbox_rule.Failed) == [thread_send.Send]
  assert thread_send.choices(inbox_rule.Settled) == [thread_send.Send]
  assert thread_send.choices(inbox_rule.Working)
    == [thread_send.Queue, thread_send.Steer]
  assert thread_send.choices(inbox_rule.ApprovalPending) == [thread_send.Send]

  assert thread_send.hold_note(inbox_rule.ApprovalPending)
    == Some(
      "This session is waiting on an approval. A message starts a new turn now; it does not decide the approval.",
    )
  assert thread_send.hold_note(inbox_rule.Working) == None
  assert thread_send.hold_note(inbox_rule.Idle) == None
}

// Send and Queue are prompts, since the gateway decides from the strand's state
// whether a prompt starts a turn or waits; only Steer is a steer.
pub fn only_steer_is_a_steer_test() {
  assert thread_send.delivery(thread_send.Send) == operator.Prompt
  assert thread_send.delivery(thread_send.Queue) == operator.Prompt
  assert thread_send.delivery(thread_send.Steer) == operator.Steer
  assert thread_send.label(thread_send.Send) == "Send"
  assert thread_send.label(thread_send.Queue) == "Queue"
  assert thread_send.label(thread_send.Steer) == "Steer"
}

// A draft with only whitespace is not sent, and one is sent up to the home
// composer's bound counted in bytes, not characters.
pub fn a_draft_is_sendable_when_it_says_something_and_fits_test() {
  assert !thread_send.sendable("")
  assert !thread_send.sendable("  \n\t ")
  assert thread_send.sendable("go on")
  assert thread_send.sendable(string.repeat("a", 16_384))
  assert !thread_send.sendable(string.repeat("a", 16_385))

  // 'é' is two bytes, so half the bound in characters is the whole bound.
  assert thread_send.sendable(string.repeat("é", 8192))
  assert !thread_send.sendable(string.repeat("é", 8193))
}

// Each state of the outbox has its words, drawn for the thread the outbox is
// about; another thread reads as unsent.
pub fn the_outbox_has_fixed_words_for_each_state_test() {
  assert thread_send.words(thread_send.Unsent, "A", "web ui") == ""
  assert thread_send.words(
      thread_send.Sending("A", operator.Prompt),
      "A",
      "web ui",
    )
    == "Sending…"
  assert thread_send.words(
      thread_send.Settled("A", operator.Prompt, Delivered(Admitted)),
      "A",
      "web ui",
    )
    == "Delivered to web ui · admitted"
  assert thread_send.words(
      thread_send.Settled("A", operator.Prompt, Delivered(Queued)),
      "A",
      "web ui",
    )
    == "Delivered to web ui · queued"
  assert thread_send.words(
      thread_send.Settled("A", operator.Prompt, Refused(NotHeld)),
      "A",
      "web ui",
    )
    == "Not sent: this home no longer holds that session"
  assert thread_send.words(
      thread_send.Settled("A", operator.Prompt, Refused(NotResident)),
      "A",
      "web ui",
    )
    == "Not sent: the session is not running"
  assert thread_send.words(
      thread_send.Settled(
        "A",
        operator.Prompt,
        Refused(NotAccepted("anything")),
      ),
      "A",
      "web ui",
    )
    == "Not sent: the session refused it"
  assert thread_send.words(
      thread_send.Settled("A", operator.Prompt, Refused(QueueFull)),
      "A",
      "web ui",
    )
    == "Not sent: its queue is full"

  assert thread_send.words(
      thread_send.Settled("A", operator.Prompt, Refused(Unanswered)),
      "A",
      "web ui",
    )
    == "No answer in time; it may have arrived. Check the session before sending again."

  // A delivered steer says what a steer does, and a delivered prompt does not.
  assert thread_send.words(
      thread_send.Settled("A", operator.Steer, Delivered(Queued)),
      "A",
      "web ui",
    )
    == "Delivered to web ui · steering: it stops the current turn and runs next"

  // An outbox about another session says nothing of this one.
  assert thread_send.words(
      thread_send.Sending("B", operator.Prompt),
      "A",
      "web ui",
    )
    == ""
  assert thread_send.words(
      thread_send.Settled("B", operator.Prompt, Delivered(Queued)),
      "A",
      "web ui",
    )
    == ""
}

// Whatever reason the daemon keeps for its log, the words a page draws carry
// none of it: a refusal's reason is the daemon's text and is never shown.
pub fn a_refusal_reason_never_reaches_the_words_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(200)
    |> qcheck.with_seed(qcheck.seed(seed))

  qcheck.run(config, qcheck.non_empty_string(), fn(text) {
    let reason = "§§" <> text <> "§§"
    let words =
      thread_send.words(
        thread_send.Settled("A", operator.Prompt, Refused(NotAccepted(reason))),
        "A",
        "web ui",
      )

    assert !string.contains(words, "§§")
    assert words == "Not sent: the session refused it"
  })
}
