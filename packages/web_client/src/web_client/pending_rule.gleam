//// The composer's pending message: what the page shows between the press of
//// Send, Queue or Steer and the server's answer, as functions of plain
//// values.
////
//// The server component owns the lane and draws a prompt's row only once a
//// capture holds it, so a press that waits on the server shows nothing until
//// then. The composer element (`web_client/composer`) bridges that wait: at
//// the press it shows the typed text at once as a pending line in its own
//// shadow root, marked "sending", or "queued" for a Queue, and clears the
//// editor. The line is never a row of the lane, which is the server's, and
//// it carries the person's own text as a text node and nothing else.
////
//// Two things end the wait, and neither needs a word over the socket. When
//// the server takes the draft it replaces the editor and this element with
//// it (`web_view/operator_page` keys them by the drafts sent), so the line
//// leaves with the element it was drawn in. When the server refuses, it keeps
//// the element and the draft, and tells the element so by raising the count
//// in the `refused` attribute (`component.refusals`: the page's own refusals
//// and the lane's, each of which retains the draft); a count that rises
//// while a line is shown means the draft was not taken, so the line goes and
//// the text goes back into the editor (`refused`). The first count heard is
//// the baseline, as the first `returned` count is, so a fresh element never
//// mistakes the refusal of an earlier press for its own. A notice that is
//// not a refusal, such as the lane saying it holds the draft until a read
//// answers, is not in the count, so the line stays until the draft is sent.
////
//// This module imports neither Lustre nor the DOM binding, so its tests run
//// on Node (`scripts/web_client_test.sh`).

import gleam/string

/// How the pressed button delivers the message, as the pending line words
/// it.
pub type Delivery {
  /// Send or Steer: the message goes to the strand now.
  Sending

  /// Queue: the daemon holds it for the next turn.
  Queueing
}

/// The message a press put in flight.
pub type Pending {
  Pending(
    /// The draft as the editor held it at the press.
    text: String,
    delivery: Delivery,
  )
}

/// Whether a pending line is shown.
pub type State {
  /// Nothing is in flight.
  Clear

  /// A press is waiting on the server.
  Shown(pending: Pending)
}

/// What the element knows of the server's refusal count, which the server
/// raises each time a submit is refused with the draft retained
/// (`component.refusals`).
pub type Refusals {
  /// The server has not yet said.
  Unheard

  /// The last count heard. A count above it is a refusal the server made
  /// after this element last looked.
  Heard(count: Int)
}

/// What a refusal count asks of the editor.
pub type Outcome {
  /// Nothing: no line was shown, or the count is not new.
  Keep

  /// The draft was refused: put `text` back in the editor.
  Restore(text: String)
}

/// The delivery a submit button stands for, from its class: the Queue button
/// is `queue` (`web_view/operator_page.submit_button`), and Send and Steer
/// both deliver now.
///
/// ## Examples
///
/// ```gleam
/// assert pending_rule.delivery("queue") == pending_rule.Queueing
/// assert pending_rule.delivery("steer") == pending_rule.Sending
/// ```
pub fn delivery(class: String) -> Delivery {
  case class {
    "queue" -> Queueing
    _ -> Sending
  }
}

/// The word the pending line carries beside the text.
///
/// ## Examples
///
/// ```gleam
/// assert pending_rule.mark(pending_rule.Queueing) == "queued"
/// ```
pub fn mark(delivery: Delivery) -> String {
  case delivery {
    Sending -> "sending"
    Queueing -> "queued"
  }
}

/// The state after a press. A draft with no word in it shows no line: an
/// image-only message has nothing to show, and the server's own refusal of an
/// empty draft is worded in the notice. A second press while a line is shown
/// replaces it, since the server answers each in turn and the editor was
/// cleared at the first.
///
/// ## Examples
///
/// ```gleam
/// assert pending_rule.pressed(pending_rule.Clear, "hi", pending_rule.Sending)
///   == pending_rule.Shown(pending_rule.Pending("hi", pending_rule.Sending))
/// assert pending_rule.pressed(pending_rule.Clear, " ", pending_rule.Sending)
///   == pending_rule.Clear
/// ```
pub fn pressed(state: State, text: String, delivery: Delivery) -> State {
  case string.trim(text) {
    "" -> state
    _ -> Shown(Pending(text:, delivery:))
  }
}

/// What a refusal count from the server changes. The first count is the
/// baseline and asks for nothing. A count above the last one heard while a
/// line is shown means the server refused the press and kept the draft, so
/// the line goes and the text is restored; one with no line shown, or one
/// that does not rise, changes nothing but what was heard.
///
/// ## Examples
///
/// ```gleam
/// let shown = pending_rule.Shown(pending_rule.Pending("hi", pending_rule.Sending))
/// assert pending_rule.refused(shown, pending_rule.Unheard, 3)
///   == #(shown, pending_rule.Heard(3), pending_rule.Keep)
/// assert pending_rule.refused(shown, pending_rule.Heard(3), 4)
///   == #(pending_rule.Clear, pending_rule.Heard(4), pending_rule.Restore("hi"))
/// ```
pub fn refused(
  state: State,
  refusals: Refusals,
  count: Int,
) -> #(State, Refusals, Outcome) {
  case refusals, state {
    Unheard, _ -> #(state, Heard(count), Keep)
    Heard(last), Shown(pending) if count > last -> #(
      Clear,
      Heard(count),
      Restore(pending.text),
    )
    Heard(last), _ if count > last -> #(state, Heard(count), Keep)
    Heard(_), _ -> #(state, refusals, Keep)
  }
}
