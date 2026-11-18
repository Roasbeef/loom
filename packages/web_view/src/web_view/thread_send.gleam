//// What the home page's inbox sends to a session, and what it says happened
//// (protocol-change/118).
////
//// The inbox's reading pane ends in a message field. The owner types a
//// message, picks a delivery and presses a button; the daemon sends it to the
//// thread's session as a prompt typed on the session's own page. This module
//// holds the closed vocabulary around that one act and nothing that draws or
//// sends: which buttons a thread offers, what the daemon's answer can be, and
//// the fixed words the outbox prints for each state.
////
//// The answer is a closed type so that the page can word every outcome from a
//// constant. The words never include text from the session, from the gateway
//// or from an error value, because the page is drawing for a principal who
//// cannot check where that text came from. A refusal that carries a reason
//// (`NotAccepted`) carries it for the daemon's log; no page draws it.
////
//// The module is pure. It holds no Lustre and performs no I/O, so the rules
//// about which delivery a state offers, and which words each answer gets, are
//// stated by tests without drawing a page.
////
//// ## Flow
////
//// `choices` → `delivery` → `Answer` → `words`
////
//// 1. `choices` says which buttons a thread's kind offers.
//// 2. `delivery` says which wire delivery a pressed button stands for.
//// 3. The daemon answers with an `Answer`.
//// 4. `words` says what the outbox prints for the page's `Outbox`.

import gleam/bit_array
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/operator.{type Delivery}
import web_view/composer
import web_view/inbox_rule.{type Kind}

/// How the gateway took a message it accepted.
pub type Admission {
  /// The strand was idle, and the message started a turn.
  Admitted

  /// The strand was busy, and the gateway holds the message until the turn
  /// ends (a prompt) or runs it first (a steer).
  Queued
}

/// Why a message was not sent. Each is worded by `words` from a constant.
pub type Refusal {
  /// The page's principal does not hold the session, or the page's standing
  /// changed since it was minted: the daemon checks both again at the press.
  NotHeld

  /// The session is saved, or its process is not running.
  NotResident

  /// The gateway refused the message for any reason but a full queue. The
  /// reason is the daemon's text, kept for its log and never drawn.
  NotAccepted(reason: String)

  /// The strand's input queue is at its bound (protocol-change/022).
  QueueFull
}

/// What the daemon answers to one send.
pub type Answer {
  /// The gateway admitted or queued the message. That is all it means: it does
  /// not say that the session read it or that a turn ran.
  Delivered(Admission)

  /// The message was not sent, and why.
  Refused(Refusal)
}

/// A button on a thread's message field.
pub type Choice {
  /// The only button of a session that is idle or failed: an ordinary prompt.
  Send

  /// A prompt that the gateway holds until the current turn ends, or, on a
  /// session with an approval pending, until the approval is decided.
  Queue

  /// A steer: it stops the current turn and runs first (protocol-change/022).
  Steer
}

/// What the page knows of its one outbox.
pub type Outbox {
  /// Nothing has been sent since the page opened, or the last send was
  /// delivered and the field cleared.
  Unsent

  /// A send to `session` is out, and the daemon has not answered.
  Sending(session: String)

  /// The daemon answered a send to `session`.
  Settled(session: String, answer: Answer)
}

/// The buttons a thread of this kind offers, in the order they are drawn.
///
/// An idle, failed or settled session takes one `Send`. A working one takes a
/// `Queue` and a `Steer`. A session with an approval pending takes a `Queue`
/// alone, because a steer to a session that waits on a person would stop
/// nothing and a prompt waits behind the approval whatever it is called.
///
/// ## Examples
///
/// ```gleam
/// assert thread_send.choices(inbox_rule.Working)
///   == [thread_send.Queue, thread_send.Steer]
/// ```
pub fn choices(kind: Kind) -> List(Choice) {
  case kind {
    inbox_rule.Idle | inbox_rule.Failed | inbox_rule.Settled -> [Send]
    inbox_rule.Working -> [Queue, Steer]
    inbox_rule.ApprovalPending -> [Queue]
  }
}

/// The delivery a button stands for. Both `Send` and `Queue` are prompts: the
/// gateway decides from the strand's state whether the prompt starts a turn or
/// waits, so the page names the one it expects and does not enforce it.
///
/// ## Examples
///
/// ```gleam
/// assert thread_send.delivery(thread_send.Queue) == operator.Prompt
/// ```
pub fn delivery(choice: Choice) -> Delivery {
  case choice {
    Send | Queue -> operator.Prompt
    Steer -> operator.Steer
  }
}

/// The button's label.
///
/// ## Examples
///
/// ```gleam
/// assert thread_send.label(thread_send.Steer) == "Steer"
/// ```
pub fn label(choice: Choice) -> String {
  case choice {
    Send -> "Send"
    Queue -> "Queue"
    Steer -> "Steer"
  }
}

/// The note a thread of this kind shows beside its buttons, or nothing. Only
/// the approval's thread has one: its message is held behind the approval,
/// which is decided on the session's own page and never here.
///
/// ## Examples
///
/// ```gleam
/// assert thread_send.hold_note(inbox_rule.Idle) == None
/// ```
pub fn hold_note(kind: Kind) -> Option(String) {
  case kind {
    inbox_rule.ApprovalPending -> Some("held behind the approval")
    inbox_rule.Idle
    | inbox_rule.Failed
    | inbox_rule.Settled
    | inbox_rule.Working -> None
  }
}

/// Whether a draft may be sent: it holds something besides whitespace and fits
/// the home composer's bound, `composer.prompt_limit` (16,384 bytes), which Home
/// already accepts and an inbox message, being a short one, does not approach.
/// Length is counted in bytes, as the wire's limit is.
///
/// ## Examples
///
/// ```gleam
/// assert thread_send.sendable("  ") == False
/// ```
pub fn sendable(text: String) -> Bool {
  string.trim(text) != ""
  && bit_array.byte_size(bit_array.from_string(text)) <= composer.prompt_limit
}

/// What the outbox prints for a thread. `name` is the thread's session name,
/// which the page draws as text. An outbox that is about another session reads
/// as unsent for this one.
///
/// ## Examples
///
/// ```gleam
/// assert thread_send.words(thread_send.Unsent, "a1", "web ui") == "Not sent"
/// ```
pub fn words(outbox: Outbox, session: String, name: String) -> String {
  case outbox {
    Unsent -> "Not sent"
    Sending(session: out) if out == session -> "Sending…"
    Settled(session: out, answer:) if out == session ->
      answer_words(answer, name)
    Sending(_) | Settled(_, _) -> "Not sent"
  }
}

/// The words for one answer.
///
/// ## Examples
///
/// ```gleam
/// assert thread_send.answer_words(thread_send.Refused(thread_send.QueueFull), "x")
///   == "Not sent: its queue is full"
/// ```
pub fn answer_words(answer: Answer, name: String) -> String {
  case answer {
    Delivered(Admitted) -> "Delivered to " <> name <> " · admitted"
    Delivered(Queued) -> "Delivered to " <> name <> " · queued"
    Refused(NotHeld) -> "Not sent: this home no longer holds that session"
    Refused(NotResident) -> "Not sent: the session is not running"
    Refused(NotAccepted(_)) -> "Not sent: the session refused it"
    Refused(QueueFull) -> "Not sent: its queue is full"
  }
}
