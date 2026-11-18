//// The inbox's threads for asks, finds and stuck strands, and the pane that
//// reads one (protocol-change/120, the attention inbox's phase 1).
////
//// A row is a button whose eyebrow names the kind and the session and whose
//// head is the model's own words, cut by the daemon. The pane draws the
//// record: an ask as one fixed component for each question's kind, a find as
//// its kind, text and place, a stuck strand as the strand's name, each with
//// the age the record's time gives (`web_view/attention_rule`).
////
//// Everything a session wrote, a question, an option's label and note, a
//// find's text and path, a strand's name, is drawn as a text node and nowhere
//// else. No attribute carries it: a control's name is a question's key
//// (`q1`..`q4`), an option's value is its position, and the handlers carry the
//// thread's key, which the server drew and the browser never names
//// (`web_view/answer_rule`). The classes are complete literals.
////
//// A page that may act is handed `Acting`, the messages its forms send. A page
//// that may not, an observer's or a member's, is handed none, and the pane
//// draws the record, its age and the words that say who can answer, and no
//// form, no staging control, no outbox and no Send. The daemon refuses the
//// frames such a page could not have sent in any case
//// (`ui_socket.home_owner_accepts`).
////
//// ## Flow
////
//// `row` → `pane` → `ask_form` / `find_body` / `stuck_body` → `outbox`
////
//// 1. `row` draws one thread in the list.
//// 2. `pane` draws the open thread's eyebrow, its record by sort and, for a
////    page that may act, the note field and the outbox.
//// 3. `ask_form` draws an ask's questions, and `question` one component each.
//// 4. `outbox` lists what is staged and the Send that delivers it.

import core/attention.{type Closure, type Question}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import web_view/answer_rule
import web_view/approval_evidence.{type Seen}
import web_view/attention_feed
import web_view/attention_rule.{type Item, type Key}
import web_view/item_pane.{type State}

/// The messages a page that may act sends from the pane.
pub type Acting(message) {
  Acting(
    /// An ask's form was submitted: its fields, to be checked and staged.
    stage: fn(List(#(String, String))) -> message,
    /// The note form was submitted: its text, to be staged.
    note: fn(String) -> message,
    /// Take back everything staged.
    unstage: message,
    /// Send what is staged.
    send: message,
    /// Close the open find in one of the three ways.
    close: fn(Closure) -> message,
    /// Ask the stuck strand to retry.
    retry: message,
  )
}

/// What the pane draws from.
pub type Offer(message) {
  Offer(
    /// The time the list was read, which ages are counted from.
    now: Int,
    /// The open thread.
    state: State,
    /// The item the key names, when the last read still holds it.
    item: Option(Item),
    /// How many threads have been opened, which keys the forms so each open
    /// starts empty.
    presses: Int,
    /// The forms' messages, or nothing for a page that may not act.
    acting: Option(Acting(message)),
    /// What "Decide on the session's page" and "Open session" send, given the
    /// session.
    open: fn(String) -> message,
  )
}

/// One thread's row: a button that opens the thread. `selected` marks the row
/// whose pane is open.
///
/// ## Examples
///
/// ```gleam
/// // attention_thread.row(item, now, selected, pick)
/// ```
pub fn row(
  item: Item,
  now: Int,
  selected: Option(Key),
  pick: fn(Key) -> message,
) -> Element(message) {
  let key = attention_rule.key_of(item)

  html.li([], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("inbox-thread inbox-item"),
        attribute.class(case selected == Some(key) {
          True -> "inbox-selected"
          False -> ""
        }),
        event.on_click(pick(key)),
      ],
      [
        html.span([attribute.class("inbox-eyebrow")], [
          html.text(eyebrow(item)),
        ]),
        html.span([attribute.class("inbox-head")], [html.text(head(item))]),
        case attention_rule.age_line(item, now) {
          Some(age) ->
            html.span([attribute.class("inbox-age")], [html.text(age)])
          None -> element.none()
        },
      ],
    ),
  ])
}

/// Which of a saved session's two counts a row draws.
pub type SavedSide {
  /// The approvals and asks that wait on the owner.
  SavedNeeding

  /// The open finds.
  SavedFinding
}

/// What a saved row offers and shows beyond its counts.
pub type SavedOffer(message) {
  SavedOffer(
    /// What the button sends, given the session: a resume. Nothing on a page
    /// that may not operate, whose rows draw no button.
    resume: Option(fn(String) -> message),
    /// The session whose resume is out, if one is: its row says so and its
    /// button waits.
    resuming: Option(String),
    /// The line the daemon's refusal of the last resume left on the row it was
    /// about, given the row's session, and nothing for any other.
    said: fn(String) -> Option(Element(message)),
  )
}

/// A saved session's row: its name and what the catalogue's summary says is
/// open, the age of the oldest open record when the summary has one, and the one
/// action it has. The session is not running, so the page's open would be
/// refused; the button asks the daemon to resume it, as the sessions table does,
/// and the page follows the ticket the answer carries. A page that may not
/// operate draws no button. A refused resume is a line on the row, since the
/// table's note is not on screen here. The name is the catalogue's text and is
/// drawn as a text node, and the button's handler carries the session, never an
/// attribute.
///
/// ## Examples
///
/// ```gleam
/// // attention_thread.saved_row(thread, SavedNeeding, now, offer)
/// ```
pub fn saved_row(
  thread: attention_rule.SavedThread,
  side: SavedSide,
  now: Int,
  offer: SavedOffer(message),
) -> Element(message) {
  // Each row draws one count: what waits on the owner, or the open finds.
  let words = case side {
    SavedNeeding -> attention_rule.needing_words(thread.saved)
    SavedFinding -> attention_rule.finding_words(thread.saved)
  }

  html.li([], [
    html.div([attribute.class("inbox-saved")], [
      html.span([attribute.class("inbox-eyebrow")], [
        html.text("Saved · " <> thread.name),
      ]),
      html.span([attribute.class("inbox-head")], [html.text(words)]),
      case attention_rule.saved_age(thread.saved, now) {
        Some(age) -> html.span([attribute.class("inbox-age")], [html.text(age)])
        None -> element.none()
      },
      // An observer's page has nothing to press, and a press out waits.
      case offer.resume {
        Some(press) -> {
          let pending = offer.resuming == Some(thread.session)

          html.button(
            [
              attribute.type_("button"),
              attribute.class("inbox-open"),
              attribute.disabled(pending),
              event.on_click(press(thread.session)),
            ],
            [
              html.text(case pending {
                True -> "Resuming…"
                False -> "Resume and open ›"
              }),
            ],
          )
        }
        None -> element.none()
      },
      option.lazy_unwrap(offer.said(thread.session), element.none),
    ]),
  ])
}

/// The pane of the open thread, or nothing when the last read no longer holds
/// it: an answered ask and a closed find leave the list, and their pane with
/// them.
///
/// ## Examples
///
/// ```gleam
/// // attention_thread.pane(offer)
/// ```
pub fn pane(offer: Offer(message)) -> Element(message) {
  case offer.item {
    // A settled record leaves the list at the next read. What was staged stays
    // in view with its outbox, so a note that failed after the answer settled
    // can be sent again, and otherwise the daemon's word stays so the owner is
    // told and not left with a blank.
    None ->
      case offer.state.progress, item_pane.has_staged(offer.state) {
        _, True ->
          html.section(
            [attribute.class("inbox-reading inbox-reading-pressed")],
            [outbox(offer)],
          )
        item_pane.Settled(words:), False ->
          html.section(
            [attribute.class("inbox-reading inbox-reading-pressed")],
            [
              html.p(
                [attribute.class("inbox-outbox"), attribute.role("status")],
                [html.text(words)],
              ),
            ],
          )
        item_pane.Resting, False | item_pane.Sending, False -> element.none()
      }
    Some(item) ->
      html.section([attribute.class("inbox-reading inbox-reading-pressed")], [
        html.p([attribute.class("inbox-eyebrow")], [html.text(eyebrow(item))]),
        case attention_rule.age_line(item, offer.now) {
          Some(age) -> html.p([attribute.class("inbox-age")], [html.text(age)])
          None -> element.none()
        },
        body(item, offer),
        message_field(offer),
        outbox(offer),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("inbox-open"),
            event.on_click(offer.open(attention_rule.session_of(item))),
          ],
          [html.text("Open session ›")],
        ),
      ])
  }
}

/// The words of a row's eyebrow: the kind, then the strand the record is about.
fn eyebrow(item: Item) -> String {
  case item {
    attention_rule.AskItem(ask:, ..) -> "Ask · " <> ask.strand
    attention_rule.FindItem(find:, ..) ->
      "Find · " <> attention.find_kind_name(find.kind) <> " · " <> find.strand
    attention_rule.StuckItem(stuck:, ..) -> "Stuck · " <> stuck.strand
  }
}

/// A row's head: the model's cut words, or fixed words for a strand.
fn head(item: Item) -> String {
  case item {
    attention_rule.AskItem(ask:, ..) -> ask.head
    attention_rule.FindItem(find:, ..) -> find.head
    attention_rule.StuckItem(..) -> "Stopped on a failed run"
  }
}

/// The record's own body, by sort.
fn body(item: Item, offer: Offer(message)) -> Element(message) {
  case item {
    attention_rule.AskItem(..) -> ask_body(offer)
    attention_rule.FindItem(find:, ..) -> find_body(find, offer)
    attention_rule.StuckItem(..) -> stuck_body(offer)
  }
}

/// An ask's body: the record once it is read, else a line that says so.
fn ask_body(offer: Offer(message)) -> Element(message) {
  case offer.state.loaded {
    item_pane.Loaded(item_pane.AskRecord(ask:, revision: _)) ->
      html.section([attribute.class("inbox-section")], [
        html.h4([attribute.class("inbox-label")], [
          html.text("The agent asks, untrusted text"),
        ]),
        case ask.why {
          Some(why) ->
            html.p([attribute.class("inbox-message")], [html.text(why)])
          None -> element.none()
        },
        ask_form(ask, offer),
      ])
    item_pane.Loaded(item_pane.FindRecord(..)) | item_pane.NoRecord ->
      element.none()
    item_pane.Loading ->
      html.p([attribute.class("inbox-standing")], [
        html.text("Reading the ask…"),
      ])
    item_pane.Unavailable(words:) ->
      html.p([attribute.class("inbox-standing")], [html.text(words)])
  }
}

/// The ask's questions as a form. A page that may not act gets the questions
/// as a list of text with the words that say who can answer, and no control.
fn ask_form(ask: attention.Ask, offer: Offer(message)) -> Element(message) {
  case offer.acting {
    None ->
      html.div([attribute.class("inbox-questions")], [
        html.ul(
          [],
          list.map(ask.questions, fn(question) {
            html.li([], [html.text(question.prompt)])
          }),
        ),
        html.p([attribute.class("inbox-hold")], [
          html.text("Only the owner's operating page can answer."),
        ]),
      ])
    Some(acting) ->
      answer_form(
        "ask-form-" <> int.to_string(offer.presses),
        ask,
        offer.state.problem,
        "Stage the answer",
        acting.stage,
      )
  }
}

/// An ask's questions as a form, one fixed component for each question's kind,
/// the refusal of the last submit in the rule's fixed words, and one submit
/// button. The inbox's pane stages the answer with it and the session page's
/// rail sends it, so both draw the same controls and read them back with the
/// same rule (`web_view/answer_rule`). The form is the caller's to place only
/// for a page that may answer.
///
/// The form is keyed by `key`, which names the ask it was drawn for. Radios and
/// checkboxes carry no `checked` in the tree, so a form that outlived its ask
/// would keep the picks of the ask that left, and the next ask that took its
/// place would be answered with them. A new key makes the browser build a new
/// form.
///
/// ## Examples
///
/// ```gleam
/// // attention_thread.answer_form("ask-1", ask, None, "Send the answer", Submitted)
/// ```
pub fn answer_form(
  key: String,
  ask: attention.Ask,
  refused: Option(answer_rule.Problem),
  label: String,
  submit: fn(List(#(String, String))) -> message,
) -> Element(message) {
  keyed.div([], [
    #(
      key,
      html.form(
        [
          attribute.class("inbox-questions"),
          event.on("submit", fields_of(submit)) |> event.prevent_default,
        ],
        list.flatten([
          list.map(ask.questions, question),
          [
            problem(refused),
            html.button(
              [attribute.type_("submit"), attribute.class("place-send")],
              [html.text(label)],
            ),
          ],
        ]),
      ),
    ),
  ])
}

/// One question with its component, chosen by the question's kind.
fn question(question: Question) -> Element(message) {
  html.fieldset([attribute.class("inbox-question")], [
    html.legend([attribute.class("inbox-label")], [html.text(question.prompt)]),
    ..case question.kind {
      attention.Confirm -> [
        radio(question, answer_rule.yes, "Yes", None),
        radio(question, answer_rule.no, "No", None),
        radio(question, answer_rule.other, "Other", None),
        other_field(question),
      ]
      attention.Choice ->
        list.flatten([
          list.index_map(question.options, fn(option, index) {
            radio(
              question,
              answer_rule.position(index),
              option.label,
              Some(option),
            )
          }),
          [
            radio(question, answer_rule.other, "Other", None),
            other_field(question),
          ],
        ])
      attention.Multiple(min:, max:) ->
        list.flatten([
          [
            html.p([attribute.class("inbox-hold")], [
              html.text(
                "Pick " <> int.to_string(min) <> " to " <> int.to_string(max),
              ),
            ]),
          ],
          boxes(question),
        ])
      attention.Checklist -> boxes(question)
      attention.Fill(format:) -> [fill(question, format)]
    }
  ])
}

/// The checkboxes of a multiple or a checklist, and the Other control.
fn boxes(question: Question) -> List(Element(message)) {
  list.flatten([
    list.index_map(question.options, fn(option, index) {
      box(question, answer_rule.position(index), option.label, Some(option))
    }),
    [box(question, answer_rule.other, "Other", None), other_field(question)],
  ])
}

/// One radio of a question. The value is a position or a word of the page's
/// own, so the label, which a model wrote, appears only as text.
fn radio(
  question: Question,
  value: String,
  label: String,
  option: Option(attention.Alternative),
) -> Element(message) {
  control("radio", question, value, label, option)
}

/// One checkbox of a question.
fn box(
  question: Question,
  value: String,
  label: String,
  option: Option(attention.Alternative),
) -> Element(message) {
  control("checkbox", question, value, label, option)
}

/// A labelled control and, for an option, the model's mark and note as text.
fn control(
  kind: String,
  question: Question,
  value: String,
  label: String,
  option: Option(attention.Alternative),
) -> Element(message) {
  html.label([attribute.class("inbox-option")], [
    html.input([
      attribute.type_(kind),
      attribute.name(answer_rule.field_name(question)),
      attribute.value(value),
    ]),
    html.span([], [html.text(label)]),
    case option {
      Some(attention.Alternative(emphasis: attention.Recommended, ..)) ->
        html.em([attribute.class("inbox-mark")], [html.text(" recommended")])
      Some(attention.Alternative(emphasis: attention.Plain, ..)) | None ->
        element.none()
    },
    case option {
      Some(attention.Alternative(note: Some(note), ..)) ->
        html.small([attribute.class("inbox-note")], [html.text(" " <> note)])
      Some(attention.Alternative(note: None, ..)) | None -> element.none()
    },
  ])
}

/// The Other text of a question.
fn other_field(question: Question) -> Element(message) {
  html.input([
    attribute.type_("text"),
    attribute.name(answer_rule.other_name(question)),
    attribute.class("composer-name"),
    attribute.aria_label("Other"),
    attribute.placeholder("Other"),
    attribute.attribute("maxlength", "1000"),
  ])
}

/// A fill question's own text control. A long text is a box, and every other
/// format a line. The format is a hint for the person and the daemon's rule is
/// the check.
fn fill(question: Question, format: attention.Format) -> Element(message) {
  let name = attribute.name(answer_rule.field_name(question))

  // A long text is a box and every other format a line, and the format is only a hint.
  case format {
    attention.LongText ->
      html.textarea(
        [
          name,
          attribute.class("composer-name"),
          attribute.attribute("rows", "4"),
          attribute.attribute("maxlength", "4000"),
        ],
        "",
      )
    attention.ShortText
    | attention.FilePath
    | attention.Number
    | attention.Url ->
      html.input([
        attribute.type_("text"),
        name,
        attribute.class("composer-name"),
        attribute.placeholder(case format {
          attention.FilePath -> "a path"
          attention.Number -> "a number"
          attention.Url -> "https://"
          attention.ShortText | attention.LongText -> ""
        }),
        attribute.attribute("maxlength", "1000"),
      ])
  }
}

/// A find's body: its kind, text and place, and its three ways to close.
fn find_body(
  find: attention_feed.Find,
  offer: Offer(message),
) -> Element(message) {
  // The record's full text is read when the page has it, and the feed's cut
  // head stands in until then.
  let text = case offer.state.loaded {
    item_pane.Loaded(item_pane.FindRecord(find: full, ..)) -> full.text
    item_pane.Loaded(item_pane.AskRecord(..))
    | item_pane.NoRecord
    | item_pane.Loading
    | item_pane.Unavailable(_) -> find.head
  }

  html.section([attribute.class("inbox-section")], [
    html.h4([attribute.class("inbox-label")], [
      html.text(
        "The agent noticed ("
        <> attention.find_kind_name(find.kind)
        <> "), untrusted text",
      ),
    ]),
    html.p([attribute.class("inbox-message")], [html.text(text)]),
    case find.path {
      Some(path) ->
        html.p([attribute.class("inbox-place")], [
          html.text(case find.line {
            Some(line) -> path <> ":" <> int.to_string(line)
            None -> path
          }),
        ])
      None -> element.none()
    },
    case offer.acting {
      Some(acting) ->
        html.div([attribute.class("cbar")], [
          close_button("Fixed", attention.Fixed, acting),
          close_button("Filed", attention.Filed, acting),
          close_button("Dismiss", attention.Dismissed, acting),
        ])
      None ->
        html.p([attribute.class("inbox-hold")], [
          html.text("Only the owner's operating page can close a find."),
        ])
    },
  ])
}

/// One of the three ways to close a find.
fn close_button(
  label: String,
  closure: Closure,
  acting: Acting(message),
) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("place-send"),
      event.on_click(acting.close(closure)),
    ],
    [html.text(label)],
  )
}

/// A stuck strand's body: what stopped, and Retry.
fn stuck_body(offer: Offer(message)) -> Element(message) {
  html.section([attribute.class("inbox-section")], [
    html.p([attribute.class("inbox-standing")], [
      html.text("This strand's last run failed and nothing has run since."),
    ]),
    case offer.acting {
      Some(acting) ->
        html.button(
          [
            attribute.type_("button"),
            attribute.class("place-send"),
            event.on_click(acting.retry),
          ],
          [html.text("Retry")],
        )
      None ->
        html.p([attribute.class("inbox-hold")], [
          html.text("Only the owner's operating page can retry."),
        ])
    },
  ])
}

/// The note field: one box that stages a message for the thread's strand. A
/// page that may not act has none.
fn message_field(offer: Offer(message)) -> Element(message) {
  case offer.acting {
    None -> element.none()
    Some(acting) ->
      html.form(
        [
          attribute.class("place-composer inbox-form"),
          event.on("submit", note_of(acting.note)) |> event.prevent_default,
        ],
        [
          html.textarea(
            [
              attribute.name("draft"),
              attribute.class("composer-name"),
              attribute.aria_label("Message this strand"),
              // The strand is in the eyebrow as text, and no attribute carries
              // a name a session chose.
              attribute.placeholder("Message this strand"),
              attribute.attribute("rows", "3"),
            ],
            "",
          ),
          html.div([attribute.class("cbar")], [
            html.button(
              [attribute.type_("submit"), attribute.class("place-send")],
              [html.text("Stage the message")],
            ),
          ]),
        ],
      )
  }
}

/// The outbox: what is staged, the refusal or the outcome in fixed words, and
/// the buttons. A page that may not act draws nothing.
fn outbox(offer: Offer(message)) -> Element(message) {
  // A page that may not act has no outbox.
  case offer.acting {
    None -> element.none()
    Some(acting) -> {
      let state = offer.state

      html.section([attribute.class("inbox-section inbox-outbox-list")], [
        html.h4([attribute.class("inbox-label")], [html.text("Outbox")]),
        case item_pane.has_staged(state) {
          False ->
            html.p([attribute.class("inbox-hold")], [
              html.text(
                "Nothing is staged. Nothing is sent until you press Send.",
              ),
            ])
          True ->
            html.ul(
              [],
              list.flatten([
                staged_answer(state),
                case state.outbox.note {
                  Some(text) -> [html.li([], [html.text("Message: " <> text)])]
                  None -> []
                },
              ]),
            )
        },
        html.p([attribute.class("inbox-outbox"), attribute.role("status")], [
          html.text(case state.progress {
            item_pane.Resting -> ""
            item_pane.Sending -> "Sending…"
            item_pane.Settled(words:) -> words
          }),
        ]),
        html.div([attribute.class("cbar")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("place-send"),
              attribute.disabled(
                !item_pane.has_staged(state)
                || state.progress == item_pane.Sending,
              ),
              event.on_click(acting.send),
            ],
            [html.text("Send")],
          ),
          html.button(
            [
              attribute.type_("button"),
              attribute.class("inbox-open"),
              attribute.disabled(!item_pane.has_staged(state)),
              event.on_click(acting.unstage),
            ],
            [html.text("Clear")],
          ),
        ]),
      ])
    }
  }
}

/// The staged answer's lines.
fn staged_answer(state: State) -> List(Element(message)) {
  case state.outbox.answer {
    Some(staged) ->
      list.map(staged.lines, fn(line) { html.li([], [html.text(line)]) })
    None -> []
  }
}

/// Why the last stage was refused, in the daemon's rule's fixed words.
fn problem(refused: Option(answer_rule.Problem)) -> Element(message) {
  case refused {
    Some(answer_rule.Problem(key:, words:)) ->
      html.p([attribute.class("inbox-standing"), attribute.role("alert")], [
        html.text(answer_rule.number(key) <> ": " <> words),
      ])
    None -> element.none()
  }
}

/// A submit's fields as the stage message. A submit the form could not have
/// made, whose pairs are not names and values, refuses the event.
fn fields_of(
  stage: fn(List(#(String, String))) -> message,
) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )
  decode.success(stage(fields))
}

/// The note form's draft: exactly one `draft` field and nothing else.
fn note_of(note: fn(String) -> message) -> decode.Decoder(message) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // The note form has one field, and any other shape is not the form that was drawn.
  case fields {
    [#("draft", text)] -> decode.success(note(text))
    _ -> decode.failure(note(""), "attention note form")
  }
}

/// One field of a submitted form: its name and its value.
fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

/// A session's approval evidence: the tool, the call's action, what held it and
/// what it wants. It decides nothing and carries no handler. Every word of it
/// is a text node, since the preview is the call's own arguments and the reason
/// and details come from a policy a model's call tripped.
///
/// ## Examples
///
/// ```gleam
/// // attention_thread.evidence(approval_evidence.Unseen("not answered"))
/// ```
pub fn evidence(seen: Seen) -> Element(message) {
  case seen {
    approval_evidence.Unseen(words:) ->
      html.p([attribute.class("inbox-hold")], [html.text(words)])
    approval_evidence.Seen(evidence: read) ->
      html.section(
        [attribute.class("inbox-section inbox-evidence")],
        list.flatten([
          [
            html.h4([attribute.class("inbox-label")], [
              html.text("What it asks for, untrusted text"),
            ]),
          ],
          list.map(read.items, approval_item),
          [more_pending(read)],
          [
            html.p([attribute.class("inbox-hold")], [
              html.text(
                "The record carries no time, so no age is shown. It is decided on the session's page.",
              ),
            ]),
          ],
        ]),
      )
  }
}

/// One pending approval's lines.
fn approval_item(item: approval_evidence.Item) -> Element(message) {
  html.dl(
    [attribute.class("inbox-evidence-item")],
    list.flatten([
      [
        html.dt([], [html.text("Tool")]),
        html.dd([], [
          html.text(case item.tool {
            "" -> "not recorded"
            tool -> tool
          }),
        ]),
      ],
      case item.preview {
        Some(preview) -> [
          html.dt([], [html.text("Action")]),
          html.dd([attribute.class("inbox-message")], [html.text(preview)]),
        ]
        None -> []
      },
      case item.reason {
        "" -> []
        reason -> [
          html.dt([], [html.text("Held by")]),
          html.dd([], [html.text(held_by(item.source) <> ": " <> reason)]),
        ]
      },
      wanted_lines(item.wanted),
    ]),
  )
}

/// The words for what held a call.
fn held_by(source: String) -> String {
  case source {
    "policy" -> "policy"
    "execution" -> "execution"
    _ -> "the harness"
  }
}

/// The grants a call wants: the network first, under its own label, then every
/// other grant.
fn wanted_lines(
  wanted: List(approval_evidence.Wanted),
) -> List(Element(message)) {
  let #(networks, others) =
    list.partition(wanted, fn(grant) { grant.kind == "network" })

  list.flatten([
    case networks {
      [] -> []
      [_, ..] -> [
        html.dt([], [html.text("Network")]),
        html.dd([], [
          html.text(string.join(
            list.map(networks, fn(grant) { grant.detail }),
            ", ",
          )),
        ]),
      ]
    },
    case others {
      [] -> []
      [_, ..] -> [
        html.dt([], [html.text("Wants")]),
        html.dd(
          [],
          list.map(others, fn(grant) {
            html.div([], [html.text(grant.kind <> " " <> grant.detail)])
          }),
        ),
      ]
    },
  ])
}

/// A line for the pending approvals the reply did not carry.
fn more_pending(read: approval_evidence.Evidence) -> Element(message) {
  case read.count - list.length(read.items) {
    left if left > 0 ->
      html.p([attribute.class("inbox-hold")], [
        html.text(int.to_string(left) <> " more pending, decided on the page."),
      ])
    _ -> element.none()
  }
}
