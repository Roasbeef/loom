//// The rule behind a project ticket's thread on Home: which tickets are
//// threads, which controls a thread draws, what one confirm click guards, and
//// how the daemon's word on an act becomes the words the pane shows
//// (protocol-change/051, the addendum on project tickets on Home).
////
//// The module is pure. It imports no Lustre, calls no daemon and reads no
//// clock, so a test states every decision without drawing a page.
//// `web_view/view/ticket_thread` draws what this module decides, and
//// `web_view/home` holds the state in its model and performs the effects.
////
//// Three rules shape it.
////
//// - A control exists only for an action the daemon listed for that ticket
////   (`project_board.offers`). The stage is never read to decide one, because
////   the daemon lists actions from the engine's own rules and a stage this
////   client does not know, `person/check` among them, would otherwise get
////   none or the wrong ones. An action word the client does not know has no
////   control. Publish is such a case for now: the board carries no reason for
////   a publish that is listed and not allowed, so there is nothing true to
////   draw beside a disabled button, and no button is drawn.
//// - A thread is acted on only by a page that may operate. The page's
////   standing is the owner at the Operator ceiling, which the home already
////   derives for its other acts, and an observing page gets the thread with no
////   controls. The daemon checks the owner again at every press.
//// - Stop and Close end a ticket's work and cannot be undone, so each asks
////   for one more click on a button that names the act. Retry and Answer are
////   sent at once: a retry asks for a new worker, and an answer is a person's
////   own words which the daemon refuses if the question has moved on.
////
//// Every string in a ticket, its title, question, stage word and pull
//// request, is external text. The decoders have made them safe to draw, and
//// the view draws each as a text node and puts none in an attribute.
////
//// ## Flow
////
//// `waiting` → `controls` → `press` → `confirmed` → `settled`
////
//// 1. `waiting` picks the tickets that need a person out of the boards, in the
////    board's own order.
//// 2. `controls` says which controls the daemon's list and the page's standing
////    leave for one ticket.
//// 3. `press` takes a control: Close and Stop ask for confirmation, and Retry
////    is sent.
//// 4. `confirmed` sends the act that was asked about, and `cancelled` takes the
////    question back.
//// 5. `settled` takes the daemon's word and makes the notice the pane shows.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import session_view/project_board.{type Detail, type Ticket} as board
import session_view/text_hygiene
import web_view/projects.{type Loaded}

/// A ticket's address: its project's id and its own, both values the page took
/// from a board it holds. The browser never names one.
pub type Key {
  Key(
    /// The project's id.
    project: String,
    /// The ticket's id.
    ticket: String,
  )
}

/// What the page may do to a ticket.
pub type Standing {
  /// The page is the owner's and was minted to operate.
  Operating

  /// Any other page. It draws the thread and its question and no control.
  Watching
}

/// A ticket on a board that needs a person, with the address that opens it.
pub type Waiting {
  Waiting(
    /// Where the ticket lives.
    key: Key,
    /// The ticket as the board holds it.
    ticket: Ticket,
  )
}

/// One thing a person can do to a ticket from its thread.
pub type Control {
  /// Answer the worker's open question. The sequence number is the question's
  /// as the pane was drawn with it, and the daemon refuses an answer to any
  /// other.
  Answer(
    /// The question's sequence number.
    seq: Int,
  )

  /// Accept the work and close the ticket. The mandate stands.
  Close

  /// Ask for a new worker.
  Retry

  /// Withdraw the ticket's mandate.
  Stop
}

/// Whether a press waits for a second click.
pub type Confirm {
  /// Nothing is being asked about.
  Unasked

  /// The pane asks whether to go ahead with an act that cannot be undone.
  Asked(
    /// The act, `Close` or `Stop`.
    control: Control,
  )
}

/// Whether an act is with the daemon.
pub type Progress {
  /// Nothing is out.
  Resting

  /// An act is with the daemon, and a second press asks nothing.
  Sending
}

/// What the pane says about the last act.
pub type Notice {
  /// The daemon took it.
  Told(
    /// The page's words for it.
    words: String,
  )

  /// The daemon refused it.
  Refused(
    /// The words for the refusal, which are the daemon's code made into a
    /// sentence and nothing a person or a worker wrote.
    words: String,
  )
}

/// The daemon's word on an act.
pub type Outcome {
  /// The act was recorded.
  Done

  /// The daemon refused it, with its error code.
  Declined(
    /// The daemon's code, such as `conflict` or `bad_request`.
    code: String,
  )
}

/// The thread the page has open.
pub type Opened {
  Opened(
    /// The ticket's address.
    key: Key,
    /// The last read of the ticket, once one has answered.
    detail: Option(Detail),
    /// Whether an act is out.
    progress: Progress,
    /// What the last act said, if one has run.
    notice: Option(Notice),
    /// The act the pane is asking about.
    confirm: Confirm,
    /// How many answers have been recorded. It keys the answer box so a
    /// recorded answer leaves an empty one.
    answered: Int,
  )
}

/// What a press asks of the page.
pub type Press {
  /// Draw the confirmation and send nothing.
  Confirming(opened: Opened)

  /// Send the act, with the opened thread marked as sending.
  Send(opened: Opened, control: Control)

  /// The press asks nothing: an act is already out, or there was nothing to
  /// confirm.
  Nothing
}

/// The tickets that need a person, project by project in the order the page
/// holds them, and within a project in the board's order (stage urgency, then
/// newest). A project whose board did not decode has none.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.waiting([]) == []
/// ```
pub fn waiting(held: List(Loaded)) -> List(Waiting) {
  list.flat_map(held, fn(project) {
    case project.board {
      Some(found) ->
        list.map(board.needing(found), fn(ticket) {
          Waiting(key: Key(project: project.id, ticket: ticket.id), ticket:)
        })
      None -> []
    }
  })
}

/// The clause the inbox's headline adds for the tickets waiting on a person, or
/// nothing when there are none.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.waiting_words(2) == "2 tickets need you"
/// ```
pub fn waiting_words(count: Int) -> String {
  case count {
    0 -> ""
    1 -> "1 ticket needs you"
    many -> int.to_string(many) <> " tickets need you"
  }
}

/// The ticket the thread draws: the last read of it when one has answered,
/// which is newer than the board's row, and otherwise the board's row. Nothing
/// when neither holds it, which closes the pane.
///
/// ## Examples
///
/// ```gleam
/// // ticket_rule.current(opened, boards)
/// ```
pub fn current(opened: Opened, held: List(Loaded)) -> Option(Ticket) {
  case opened.detail {
    Some(read) -> Some(read.ticket)
    None ->
      projects.find(held, opened.key.project, opened.key.ticket)
      |> option.from_result
  }
}

/// The controls a ticket's thread draws, in a fixed order: Answer, Close,
/// Retry, Stop. Each is there only when the daemon lists its action for the
/// ticket and the page may operate. Answer also needs the open question whose
/// number it carries. Publish and any action this client does not know have
/// none.
///
/// ## Examples
///
/// ```gleam
/// // ticket_rule.controls(ticket, ticket_rule.Watching) == []
/// ```
pub fn controls(ticket: Ticket, standing: Standing) -> List(Control) {
  case standing {
    Watching -> []
    Operating ->
      list.flatten([
        case board.offers(ticket, board.CanAnswer), ticket.question {
          True, Some(asked) -> [Answer(asked.seq)]
          True, None | False, _ -> []
        },
        offered(ticket, board.CanClose, Close),
        offered(ticket, board.CanRetry, Retry),
        offered(ticket, board.CanStop, Stop),
      ])
  }
}

/// A control that the daemon lists for the ticket, as a one-element list.
fn offered(
  ticket: Ticket,
  wanted: board.Action,
  control: Control,
) -> List(Control) {
  case board.offers(ticket, wanted) {
    True -> [control]
    False -> []
  }
}

/// Whether a control is among those the ticket's thread draws now. A press is
/// honoured only when it is, so a press that was drawn for a ticket the next
/// read has since changed, or one a forged frame names, asks nothing.
///
/// ## Examples
///
/// ```gleam
/// // ticket_rule.allowed(ticket, ticket_rule.Operating, ticket_rule.Stop)
/// ```
pub fn allowed(ticket: Ticket, standing: Standing, control: Control) -> Bool {
  list.contains(controls(ticket, standing), control)
}

/// Opens a thread with nothing read, nothing asked and nothing said.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.open(ticket_rule.Key("p1", "t-a")).progress
///   == ticket_rule.Resting
/// ```
pub fn open(key: Key) -> Opened {
  Opened(
    key:,
    detail: None,
    progress: Resting,
    notice: None,
    confirm: Unasked,
    answered: 0,
  )
}

/// Takes a read of the ticket. A newer read replaces the older.
///
/// ## Examples
///
/// ```gleam
/// // ticket_rule.heard(opened, detail)
/// ```
pub fn heard(opened: Opened, detail: Detail) -> Opened {
  Opened(..opened, detail: Some(detail))
}

/// Takes a read of the ticket that could not be decoded: the pane says so and
/// keeps what it had.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.unreadable(ticket_rule.open(key)).notice
///   == Some(ticket_rule.Refused("This ticket could not be read."))
/// ```
pub fn unreadable(opened: Opened) -> Opened {
  Opened(
    ..opened,
    notice: Some(Refused(words: "This ticket could not be read.")),
  )
}

/// A press on a control. Close and Stop cannot be undone, so the first press
/// only asks: the pane then names the act on a button, and `confirmed` sends
/// it. A press on the other of the two replaces the question. Retry and Answer
/// are sent at once. Nothing is asked while an act is out.
///
/// ## Examples
///
/// ```gleam
/// // ticket_rule.press(opened, ticket_rule.Stop)
/// ```
pub fn press(opened: Opened, control: Control) -> Press {
  case opened.progress, control {
    Sending, _ -> Nothing
    Resting, Close | Resting, Stop ->
      Confirming(Opened(..opened, confirm: Asked(control), notice: None))
    Resting, Retry | Resting, Answer(_) -> Send(sending(opened), control)
  }
}

/// The press on the confirmation's button: sends the act that was asked
/// about. With nothing asked, or an act already out, it sends nothing.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.confirmed(ticket_rule.open(key)) == ticket_rule.Nothing
/// ```
pub fn confirmed(opened: Opened) -> Press {
  case opened.progress, opened.confirm {
    Resting, Asked(control) -> Send(sending(opened), control)
    Sending, _ | Resting, Unasked -> Nothing
  }
}

/// The press on the confirmation's "Keep": takes the question back and sends
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.cancelled(ticket_rule.open(key)).confirm
///   == ticket_rule.Unasked
/// ```
pub fn cancelled(opened: Opened) -> Opened {
  Opened(..opened, confirm: Unasked)
}

/// Marks an act as out, clearing the confirmation and the last notice.
fn sending(opened: Opened) -> Opened {
  Opened(..opened, progress: Sending, confirm: Unasked, notice: None)
}

/// Takes the daemon's word on an act. Either way the daemon has judged it, so
/// the pane is ready again. A recorded answer counts toward the answer box's
/// key so the box is emptied, and a refused one leaves the box as typed.
///
/// ## Examples
///
/// ```gleam
/// // ticket_rule.settled(opened, ticket_rule.Close, ticket_rule.Done)
/// ```
pub fn settled(opened: Opened, control: Control, outcome: Outcome) -> Opened {
  case outcome, control {
    Done, Answer(_) ->
      Opened(
        ..opened,
        progress: Resting,
        notice: Some(Told(done_words(control))),
        answered: opened.answered + 1,
      )
    Done, Close | Done, Retry | Done, Stop ->
      Opened(
        ..opened,
        progress: Resting,
        notice: Some(Told(done_words(control))),
      )
    Declined(code:), _ ->
      Opened(
        ..opened,
        progress: Resting,
        notice: Some(Refused(refusal_words(control, code))),
      )
  }
}

/// The words for an act the daemon recorded.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.done_words(ticket_rule.Close) == "Ticket closed."
/// ```
pub fn done_words(control: Control) -> String {
  case control {
    Answer(_) -> "Answer queued for the worker."
    Close -> "Ticket closed."
    Retry -> "A new worker was requested."
    Stop -> "Ticket stopped."
  }
}

/// The words for an act the daemon refused, given its error code. An answer
/// and a close are worded by the board's own rule, so the web and the terminal
/// say the same thing. A code this client has no sentence for is shown made
/// safe, because it is the daemon's text.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.refusal_words(ticket_rule.Stop, "not_found")
///   == "That ticket no longer exists."
/// ```
pub fn refusal_words(control: Control, code: String) -> String {
  case control, code {
    Answer(_), _ -> board.answer_refusal_words(code)
    Close, _ -> board.close_refusal_words(code)
    Retry, "not_found" | Stop, "not_found" -> "That ticket no longer exists."
    Retry, "forbidden" -> "Only the owner can retry a project's ticket."
    Stop, "forbidden" -> "Only the owner can stop a project's ticket."
    Retry, "bad_request" -> "That ticket cannot be retried now."
    Stop, "bad_request" ->
      "That ticket cannot be stopped: it has ended or was already stopped."
    Retry, _ ->
      "The daemon refused the retry (" <> text_hygiene.single_line(code) <> ")."
    Stop, _ ->
      "The daemon refused the stop (" <> text_hygiene.single_line(code) <> ")."
  }
}

/// The word a control's button carries.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.control_words(ticket_rule.Retry) == "Retry"
/// ```
pub fn control_words(control: Control) -> String {
  case control {
    Answer(_) -> "Send answer"
    Close -> "Close ticket"
    Retry -> "Retry"
    Stop -> "Stop"
  }
}

/// The question the confirmation asks, which names the act and says that it
/// cannot be undone.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.confirm_words(ticket_rule.Stop)
///   == "Stop this ticket? Its mandate is withdrawn and this cannot be undone."
/// ```
pub fn confirm_words(control: Control) -> String {
  case control {
    Stop ->
      "Stop this ticket? Its mandate is withdrawn and this cannot be undone."
    Close ->
      "Close this ticket? The work is accepted and the ticket ends; only a later message can resume it."
    Answer(_) | Retry -> ""
  }
}

/// Whether the thread's open ticket is missing or older than its project's
/// board, so a read of it is due. A board that moved while the thread was open
/// costs a read, and a board that did not costs nothing.
///
/// ## Examples
///
/// ```gleam
/// assert ticket_rule.stale(ticket_rule.open(key), []) == True
/// ```
pub fn stale(opened: Opened, held: List(Loaded)) -> Bool {
  case opened.detail {
    None -> True
    Some(read) ->
      case list.find(held, fn(each) { each.id == opened.key.project }) {
        Ok(projects.Loaded(board: Some(found), ..)) ->
          read.revision < found.revision
        Ok(projects.Loaded(board: None, ..)) | Error(Nil) -> False
      }
  }
}
