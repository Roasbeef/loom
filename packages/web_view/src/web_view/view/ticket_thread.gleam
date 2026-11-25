//// The inbox's thread for a project ticket that waits on a person, and the
//// pane that reads it (protocol-change/051, the addendum on project tickets on
//// Home; `docs/design-notes/attention-inbox/README.md`, phase 2).
////
//// A row is `view/inbox_parts`' two-line row: a dot, the ticket's id and stage
//// and how long ago it opened, then a chip and the ticket's title as the head.
//// The pane shows the stage, the title, why the ticket was allowed, the worker's
//// question and the ticket's pull request, with the answer's Send in the outbox
//// bar at the pane's foot. The board carries no branch and no diff stat, so none
//// is drawn, and it carries no check result, so a `person/check` ticket shows
//// its stage word and nothing more. `Offer.check` is where a later layer's
//// check output goes: drawn as the final design does when it is `Some`, and
//// absent when it is `None`.
////
//// Everything a ticket holds, its title, its stage word, its question and
//// options, its pull request and the daemon's reason for a failure, is drawn
//// as a text node and nowhere else. No attribute, class or key carries it. The
//// handlers carry the ticket's address, which the server drew into them, and
//// the answer form carries the question's sequence number, which the page drew
//// and the daemon checks again. The classes are complete literals.
////
//// The controls are the ones `web_view/ticket_rule.controls` leaves, so this
//// module decides none. Close and Stop first turn into a question that names
//// the act, with a button that confirms it and one that keeps the ticket. A
//// page that may not operate is handed no controls and draws the words that
//// say who can act.
////
//// ## Flow
////
//// `row` → `pane` → `question` → `answer_form` / `controls`
////
//// 1. `row` draws one thread in the list.
//// 2. `pane` draws the ticket's stage, title, facts and notice.
//// 3. `question` draws what the worker asked, and the answer form when the
////    daemon lists an answer.
//// 4. `controls` draws a button for each other act, or the confirmation for
////    one that was pressed.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/project_board as board
import web_view/ticket_rule.{type Control, type Key, type Opened, type Waiting}
import web_view/view/inbox_parts as parts

/// The most characters of an answer the box takes, which is the ticket page's.
pub const answer_limit = 8192

/// What the pane draws from, and the messages its buttons send.
pub type Offer(message) {
  Offer(
    /// The time the board was read, which the ticket's age counts from.
    now: Int,
    /// The open thread: its address, its last read, its notice and what it is
    /// asking about.
    opened: Opened,
    /// The ticket the thread draws, from its last read or the board's row.
    ticket: board.Ticket,
    /// What the page may do to a ticket.
    standing: ticket_rule.Standing,
    /// The controls the daemon's list and the page's standing leave.
    controls: List(Control),
    /// What a press on a control sends. The control was drawn into the handler.
    press: fn(Control) -> message,
    /// What the answer form's submit sends: the question's sequence number it
    /// was drawn with, and the text.
    answer: fn(Int, String) -> message,
    /// What the confirmation's button sends, given the ticket's address and the
    /// act it asks about. Both are drawn into the handler.
    confirm: fn(Key, Control) -> message,
    /// What the confirmation's "Keep" sends.
    keep: message,
    /// What the pane's back control sends on a narrow screen: show the list.
    back: message,
    /// The output of the ticket's last check, when the board carries one. It
    /// does not today, so the page passes `None` and the pane draws no section.
    check: Option(String),
  )
}

/// One ticket's row: a button that opens its thread. The name is the ticket's
/// id and stage word, the chip says "Ticket" and the head is the title. The age
/// is how long ago the opening message arrived, and none when the board did not
/// say.
///
/// ## Examples
///
/// ```gleam
/// // ticket_thread.row(waiting, now, None, set.new(), Picked)
/// ```
pub fn row(
  waiting: Waiting,
  now: Int,
  selected: Option(Key),
  opened: Set(String),
  pick: fn(Key) -> message,
) -> Element(message) {
  let ticket = waiting.ticket

  parts.row(
    parts.Facts(
      reading: parts.reading(opened, ticket_rule.opened_key(waiting.key)),
      name: ticket.id <> " · " <> stage_words(ticket.stage),
      age: option.map(ticket.opened_ms, fn(_) {
        parts.Age(board.age_words(ticket.opened_ms, now), parts.Ordinary)
      }),
      kind: "Ticket",
      head: parts.words(board.title_words(ticket)),
      selection: case selected == Some(waiting.key) {
        True -> parts.Selected
        False -> parts.Unselected
      },
    ),
    pick(waiting.key),
  )
}

/// The pane of the open ticket thread.
///
/// ## Examples
///
/// ```gleam
/// // ticket_thread.pane(offer)
/// ```
pub fn pane(offer: Offer(message)) -> Element(message) {
  let ticket = offer.ticket

  parts.pane(
    parts.ByPress,
    offer.back,
    [
      parts.eyebrow(
        "Ticket",
        ticket.id <> " · " <> stage_words(ticket.stage),
        None,
      ),
      parts.title(board.title_words(ticket)),
      html.p([attribute.class("inbox-meta")], [
        html.text(
          board.opened_words(ticket.opened_ms, offer.now)
          <> ". "
          <> board.mandate_words(ticket.mandate),
        ),
      ]),
      failure(ticket),
      pull_request(ticket),
      checked(offer.check),
      question(offer),
      controls(offer),
    ],
    outbox(offer),
  )
}

/// The stage word a thread draws beside the ticket's id.
///
/// The board's own word is used for every stage but one. `person/check` is
/// drawn as the daemon spells it, because what that stage is called on the
/// inbox waits on the owner's ruling on question 6 of
/// `docs/design-notes/attention-inbox/README.md`. Until then the thread must
/// not name the stage in words of its own, such as the board's "check failed".
fn stage_words(stage: board.Stage) -> String {
  case stage {
    board.PersonCheck -> "person/check"
    board.PersonDelivery
    | board.PersonAnswer
    | board.PersonReview
    | board.PersonBlocked
    | board.PersonFailed
    | board.Queued
    | board.Idle
    | board.Working
    | board.Ended(_)
    | board.UnknownStage(_) -> board.stage_word(stage)
  }
}

/// The ticket's check output under its own label, when the board carries one.
/// The text is the check's own output, so it is a text node.
fn checked(check: Option(String)) -> Element(message) {
  case check {
    Some(output) ->
      parts.section("Check output", [
        html.pre([attribute.class("inbox-out")], [html.text(output)]),
      ])
    None -> element.none()
  }
}

/// The bar at the pane's foot: the answer's Send when the page holds an Answer
/// control for the open question, and what the page last said about an act.
fn outbox(offer: Offer(message)) -> Element(message) {
  let sending = offer.opened.progress == ticket_rule.Sending

  // The answer's Send is drawn only for a question the daemon lists an Answer
  // control for.
  let answering = case offer.ticket.question {
    Some(asked) -> list.contains(offer.controls, ticket_rule.Answer(asked.seq))
    None -> False
  }

  // With nothing to answer the bar shows only what the page said about an act.
  case answering, offer.opened.notice {
    False, None -> element.none()
    False, Some(_) ->
      parts.outbox_bar(
        "",
        notice_words(offer.opened.notice),
        [],
        element.none(),
      )
    True, _ ->
      parts.outbox_bar(
        "Not sent.",
        case notice_words(offer.opened.notice) {
          "" -> "Nothing is sent until you press Send answer."
          words -> words
        },
        [],
        html.button(
          [
            attribute.type_("submit"),
            attribute.attribute("form", answer_form_id),
            attribute.class("inbox-primary"),
            attribute.disabled(sending),
          ],
          [
            html.text(case offer.opened.progress {
              ticket_rule.Sending -> "Sending"
              ticket_rule.Resting -> "Send answer"
            }),
          ],
        ),
      )
  }
}

/// The words of the page's last statement about an act, or none.
fn notice_words(notice: Option(ticket_rule.Notice)) -> String {
  case notice {
    None -> ""
    Some(ticket_rule.Told(words)) -> words
    Some(ticket_rule.Refused(words)) -> words
  }
}

/// The id of the answer form, which the bar's Send names in its `form`
/// attribute. Only one ticket's thread is open at a time.
const answer_form_id = "inbox-answer-form"

/// The daemon's reason for a worker that never reported, when it gave one.
fn failure(ticket: board.Ticket) -> Element(message) {
  case ticket.failure {
    Some(why) ->
      html.p([attribute.class("inbox-meta")], [
        html.text("The worker failed: " <> why),
      ])
    None -> element.none()
  }
}

/// The ticket's pull request address as text, once there is one. It is not a
/// link: the address is text a worker reported.
fn pull_request(ticket: board.Ticket) -> Element(message) {
  case ticket.pull_request {
    Some(address) ->
      html.p([attribute.class("inbox-meta")], [
        html.text("Pull request: " <> address),
      ])
    None -> element.none()
  }
}

/// The worker's question with its options, and the answer form when the page
/// holds an Answer control for it. A ticket with no open question says so.
fn question(offer: Offer(message)) -> Element(message) {
  case offer.ticket.question {
    None ->
      html.p([attribute.class("inbox-meta")], [html.text("No open question.")])
    Some(asked) ->
      parts.section("The worker's question", [
        parts.quote("The worker asks, untrusted text", asked.text),
        case asked.options {
          [] -> element.none()
          found ->
            html.p([attribute.class("inbox-meta")], [
              html.text("Options: " <> string.join(found, " · ")),
            ])
        },
        answer_form(offer, asked.seq),
      ])
  }
}

/// The answer form, or nothing when the page holds no Answer control for this
/// question. The box is keyed by how many answers were recorded, so a recorded
/// answer leaves an empty box and a refused one keeps the text.
fn answer_form(offer: Offer(message), seq: Int) -> Element(message) {
  case list.contains(offer.controls, ticket_rule.Answer(seq)) {
    False -> element.none()
    True ->
      keyed.div([attribute.class("inbox-send")], [
        #(
          "ticket-answer-"
            <> offer.opened.key.project
            <> "-"
            <> offer.opened.key.ticket
            <> "-"
            <> int.to_string(seq)
            <> "-"
            <> int.to_string(offer.opened.answered),
          html.form(
            [
              attribute.id(answer_form_id),
              attribute.class("inbox-form"),
              event.on("submit", submitted(seq, offer.answer))
                |> event.prevent_default,
            ],
            [
              html.textarea(
                [
                  attribute.name("answer"),
                  attribute.class("inbox-ta"),
                  attribute.aria_label("Answer"),
                  attribute.placeholder("Answer the worker"),
                  attribute.attribute("rows", "3"),
                  attribute.attribute("maxlength", int.to_string(answer_limit)),
                ],
                "",
              ),
            ],
          ),
        ),
      ])
  }
}

/// The form's submit as the message that carries its one text field. Any other
/// field, a repeated one or a missing one refuses the event.
fn submitted(
  seq: Int,
  answer: fn(Int, String) -> message,
) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // The form has exactly one field, so anything else is a forged event.
  case fields {
    [#("answer", text)] -> decode.success(answer(seq, text))
    _ -> decode.failure(answer(seq, ""), "ticket answer form")
  }
}

/// One field of a submitted form: its name and its value.
fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// The buttons for Close, Retry and Stop, in the rule's order, or the
/// confirmation when one of the acts that cannot be undone was pressed. A page
/// that holds no control says who can act.
fn controls(offer: Offer(message)) -> Element(message) {
  let buttons =
    list.filter(offer.controls, fn(control) {
      case control {
        ticket_rule.Answer(_) -> False
        ticket_rule.Close | ticket_rule.Retry | ticket_rule.Stop -> True
      }
    })

  // A page that may not operate draws words and no button. One that may draws
  // the confirmation when an act was asked about, and otherwise one button for
  // each control left.
  case offer.standing, offer.opened.confirm, buttons {
    ticket_rule.Watching, _, _ ->
      html.p([attribute.class("inbox-meta")], [
        html.text("Only the owner's operating page can act on a ticket."),
      ])
    ticket_rule.Operating, ticket_rule.Asked(control), _ ->
      case list.contains(offer.controls, control) {
        True -> confirmation(offer, control)
        False -> buttons_row(offer, buttons)
      }
    ticket_rule.Operating, ticket_rule.Unasked, _ -> buttons_row(offer, buttons)
  }
}

/// A button for each control left, or nothing when none is.
fn buttons_row(
  offer: Offer(message),
  buttons: List(Control),
) -> Element(message) {
  case buttons {
    [] -> element.none()
    [_, ..] ->
      html.div(
        [attribute.class("inbox-acts")],
        list.map(buttons, fn(control) {
          html.button(
            [
              attribute.type_("button"),
              attribute.class("inbox-btn"),
              attribute.disabled(offer.opened.progress == ticket_rule.Sending),
              event.on_click(offer.press(control)),
            ],
            [html.text(ticket_rule.control_words(control))],
          )
        }),
      )
  }
}

/// The question that guards Stop or Close: it names the act, says that it
/// cannot be undone, and offers a button that does it and one that does not.
fn confirmation(offer: Offer(message), control: Control) -> Element(message) {
  html.div([attribute.class("inbox-section")], [
    html.p([attribute.class("inbox-meta"), attribute.role("alert")], [
      html.text(ticket_rule.confirm_words(control)),
    ]),
    html.div([attribute.class("inbox-acts")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("inbox-btn"),
          attribute.disabled(offer.opened.progress == ticket_rule.Sending),
          event.on_click(offer.confirm(offer.opened.key, control)),
        ],
        [html.text("Confirm: " <> ticket_rule.control_words(control))],
      ),
      html.button(
        [
          attribute.type_("button"),
          attribute.class("inbox-btn"),
          event.on_click(offer.keep),
        ],
        [html.text("Keep")],
      ),
    ]),
  ])
}
