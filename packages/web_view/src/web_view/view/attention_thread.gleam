//// The inbox's threads for asks, finds and stuck strands, and the pane that
//// reads one (protocol-change/120, the attention inbox's phase 1).
////
//// A row is `view/inbox_parts`' two-line row: a dot, the session's name and the
//// age the record's time gives, then a chip with the kind and the model's own
//// words as the head, cut by the daemon. The pane is the same module's frame: an
//// eyebrow, the head as a title, the record's body and an outbox bar at its foot.
//// The pane draws the record: an ask as one fixed component for each question's
//// kind, a find as its kind, text and place, a stuck strand as the strand's name
//// (`web_view/attention_rule`).
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
//// 2. `pane` draws the open thread's eyebrow and title, its record by sort and,
////    for a page that may act, the note field.
//// 3. `ask_form` draws an ask's questions, and `question` one component each.
//// 4. `outbox` draws the bar at the pane's foot: what is staged and the Send
////    that delivers it.

import core/attention.{type Closure, type Question}
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
import web_view/answer_rule
import web_view/approval_evidence.{type Seen}
import web_view/attention_feed
import web_view/attention_rule.{type Item, type Key}
import web_view/item_pane.{type State}
import web_view/session_brief.{type Brief}
import web_view/thread_words.{type Phrase}
import web_view/view/brief_view
import web_view/view/inbox_parts as parts
import web_view/view/phrase

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
    /// What the pane's back control sends on a narrow screen: show the list.
    back: message,
    /// The session's name in the page's own words, for the eyebrow.
    session_name: String,
    /// The brief of the item's session, when one was read: the agent's latest
    /// message and the coordinator's goal and strands, which an ask draws.
    brief: Option(Brief),
  )
}

/// One thread's row: a button that opens the thread. `selected` marks the row
/// whose pane is open, and `name_of` words a session's name, which the feed's
/// rows do not carry.
///
/// ## Examples
///
/// ```gleam
/// // attention_thread.row(item, now, selected, opened, pick, name_of)
/// ```
pub fn row(
  item: Item,
  now: Int,
  selected: Option(Key),
  opened: Set(String),
  pick: fn(Key) -> message,
  name_of: fn(String) -> String,
) -> Element(message) {
  let key = attention_rule.key_of(item)

  parts.row(
    parts.Facts(
      reading: parts.reading(opened, attention_rule.opened_key(key)),
      name: row_name(item, name_of),
      age: aged(item, now),
      kind: kind_word(item),
      head: head(item),
      selection: case selected == Some(key) {
        True -> parts.Selected
        False -> parts.Unselected
      },
    ),
    pick(key),
  )
}

/// The name a row draws on its first line: the session's, for a record of the
/// session's main strand, and the strand's own for a record of any other, so two
/// rows of one session that are about different strands do not read alike. The
/// strand is cut to `strand_limit` graphemes without the identifier the agency
/// appends to a sub-agent's name, which tells siblings of one purpose apart in
/// the data and not on a row.
fn row_name(item: Item, name_of: fn(String) -> String) -> String {
  // Each kind of record names the strand it is about.
  let strand = case item {
    attention_rule.AskItem(ask:, ..) -> ask.strand
    attention_rule.FindItem(find:, ..) -> find.strand
    attention_rule.StuckItem(stuck:, ..) -> stuck.strand
  }

  // The main strand is the session itself and keeps the session's name.
  case strand {
    "main" -> name_of(attention_rule.session_of(item))
    other -> strand_name(other)
  }
}

/// The most graphemes of a strand's name that a row keeps.
const strand_limit = 36

/// A strand's name as a row's name. The sixteen hexadecimal digits the agency
/// appends to a sub-agent's name are cut to `-…` and their last four, which keep
/// two siblings of one purpose apart (`audit-…cdef`), and a name still longer
/// than `strand_limit` has its purpose cut and ends in `…` before that tail.
///
/// ## Examples
///
/// ```gleam
/// assert attention_thread.strand_name("sub:main/audit-0123456789abcdef")
///   == "sub:main/audit-…cdef"
/// ```
pub fn strand_name(strand: String) -> String {
  let graphemes = string.to_graphemes(strand)
  let count = list.length(graphemes)
  let tail = list.drop(graphemes, count - 17)

  // A name shorter than the suffix cannot carry it, so only a long name whose
  // tail is a dash and sixteen hexadecimal digits has a tail to keep.
  let #(purpose, kept) = case count > 17, tail {
    True, ["-", ..digits] ->
      case list.all(digits, is_hex) {
        True -> #(
          string.concat(list.take(graphemes, count - 17)),
          "-…" <> string.concat(list.drop(digits, 12)),
        )
        False -> #(strand, "")
      }
    True, [] | False, _ | True, [_, ..] -> #(strand, "")
  }

  let room = strand_limit - string.length(kept)

  // A purpose over the room is cut and marked as cut.
  case string.length(purpose) > room {
    True -> string.slice(purpose, 0, room - 1) <> "…" <> kept
    False -> purpose <> kept
  }
}

/// Whether a grapheme is a lowercase hexadecimal digit.
fn is_hex(grapheme: String) -> Bool {
  string.contains("0123456789abcdef", grapheme) && grapheme != ""
}

/// The age a row draws, marked when an ask or a stuck strand has waited on the
/// owner for an hour or more. A find waits on no one, so its age is never marked.
fn aged(item: Item, now: Int) -> Option(parts.Age) {
  case attention_rule.row_age(item, now), attention_rule.row_wait(item, now) {
    Some(words), Some(wait) ->
      Some(
        parts.Age(words:, standing: case item, thread_words.overdue(wait) {
          attention_rule.FindItem(..), _ | _, False -> parts.Ordinary
          _, True -> parts.Overdue
        }),
      )
    _, _ -> None
  }
}

/// The word of the row's chip: the kind, and for a find the find's own kind.
fn kind_word(item: Item) -> String {
  case item {
    attention_rule.AskItem(..) -> "Ask"
    attention_rule.StuckItem(..) -> "Stuck"
    attention_rule.FindItem(find:, ..) ->
      string.capitalise(attention.find_kind_name(find.kind))
  }
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

  parts.static_row(
    parts.Facts(
      reading: parts.Unread,
      name: thread.name,
      age: None,
      kind: "Saved",
      head: parts.words(case attention_rule.saved_age(thread.saved, now) {
        Some(age) -> words <> " · " <> age
        None -> words
      }),
      selection: parts.Unselected,
    ),
    [
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
    ],
  )
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
        _, True -> parts.pane(parts.ByPress, offer.back, [], outbox(offer))
        item_pane.Settled(words:), False ->
          parts.pane(
            parts.ByPress,
            offer.back,
            [
              html.p(
                [attribute.class("inbox-outbox"), attribute.role("status")],
                [
                  html.text(words),
                ],
              ),
            ],
            element.none(),
          )
        item_pane.Resting, False | item_pane.Sending, False -> element.none()
      }
    Some(item) ->
      parts.pane(
        parts.ByPress,
        offer.back,
        [
          parts.eyebrow(
            kind_word(item),
            eyebrow(item, offer.session_name),
            moment(item),
          ),
          parts.title(title_of(item, offer)),
          case item, attention_rule.age_line(item, offer.now) {
            // A stuck strand states its failure in its own body.
            attention_rule.StuckItem(..), _ -> element.none()
            _, Some(age) ->
              html.p([attribute.class("inbox-meta")], [html.text(age)])
            _, None -> element.none()
          },
          body(item, offer),
          message_field(offer),
          html.div([attribute.class("inbox-acts")], [
            html.button(
              [
                attribute.type_("button"),
                attribute.class("inbox-open"),
                event.on_click(offer.open(attention_rule.session_of(item))),
              ],
              [html.text("Open session ›")],
            ),
          ]),
        ],
        outbox(offer),
      )
  }
}

/// The quiet words of a pane's eyebrow: the session's name and the strand the
/// record is about.
fn eyebrow(item: Item, session_name: String) -> String {
  case item {
    attention_rule.AskItem(ask:, ..) -> session_name <> " · " <> ask.strand
    attention_rule.FindItem(find:, ..) -> session_name <> " · " <> find.strand
    attention_rule.StuckItem(stuck:, ..) ->
      session_name <> " · " <> stuck.strand
  }
}

/// A row's head: the model's cut words, or fixed words for a strand, which name
/// the time it failed when the daemon could read it (`Rate-limited at 13:52`).
fn head(item: Item) -> Phrase {
  case item {
    attention_rule.AskItem(ask:, ..) -> parts.words(ask.head)
    attention_rule.FindItem(find:, ..) -> parts.words(find.head)
    attention_rule.StuckItem(stuck:, ..) ->
      thread_words.stuck_head(
        thread_words.kind_of(stuck.reason),
        stuck.failed_at,
      )
  }
}

/// The pane's title. An ask whose record was read is titled by its first
/// question in full, which the form then does not draw a second time, since the
/// row's head is that question cut. An ask not yet read keeps the head. A stuck
/// strand's title is the sentence its reason code words, and a find's is its
/// head.
fn title_of(item: Item, offer: Offer(message)) -> String {
  case item, offer.state.loaded {
    attention_rule.StuckItem(stuck:, ..), _ ->
      thread_words.stuck_title(thread_words.kind_of(stuck.reason))
    attention_rule.AskItem(ask: head, ..),
      item_pane.Loaded(item_pane.AskRecord(ask:, ..))
    ->
      case ask.questions {
        [first, ..] -> first.prompt
        [] -> head.head
      }
    attention_rule.AskItem(ask:, ..), _ -> ask.head
    attention_rule.FindItem(find:, ..), _ -> find.head
  }
}

/// The time the pane's eyebrow dates: when an ask was asked and when a stuck
/// strand failed. A find waits on no one, and a stuck strand whose time the
/// daemon could not read has none.
fn moment(item: Item) -> Option(parts.Moment) {
  case item {
    attention_rule.AskItem(ask:, ..) ->
      Some(parts.Moment("asked", ask.created_at))
    attention_rule.StuckItem(stuck:, ..) ->
      option.map(stuck.failed_at, parts.Moment("failed", _))
    attention_rule.FindItem(..) -> None
  }
}

/// The record's own body, by sort.
fn body(item: Item, offer: Offer(message)) -> Element(message) {
  case item {
    attention_rule.AskItem(..) ->
      element.fragment([
        where_it_stopped(offer),
        coordinator(offer),
        ask_body(offer),
      ])
    attention_rule.FindItem(find:, ..) -> find_body(find, offer)
    attention_rule.StuckItem(stuck:, ..) -> stuck_body(stuck, offer)
  }
}

/// The agent's latest message under "Where it stopped", from the session's
/// brief. Nothing when no brief was read or it holds no message.
fn where_it_stopped(offer: Offer(message)) -> Element(message) {
  case offer.brief {
    Some(read) -> brief_view.stopped(read)
    None -> element.none()
  }
}

/// The coordinator's card, when the session's brief has a goal or strands.
fn coordinator(offer: Offer(message)) -> Element(message) {
  case offer.brief {
    Some(read) -> brief_view.coordinator(read)
    None -> element.none()
  }
}

/// An ask's body: the record once it is read, else a line that says so.
fn ask_body(offer: Offer(message)) -> Element(message) {
  case offer.state.loaded {
    item_pane.Loaded(item_pane.AskRecord(ask:, revision: _)) ->
      parts.section(questions_label(ask), [
        case ask.why {
          Some(why) -> parts.quote("The agent asks, untrusted text", why)
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

/// The label over an ask's questions: `Options` for the usual single question,
/// whose title already says it, and `Questions` for several.
fn questions_label(ask: attention.Ask) -> String {
  // Only an ask with more than one question needs the plural word.
  case ask.questions {
    [_, _, ..] -> "Questions"
    [_] | [] -> "Options"
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

/// An ask's questions as text, for a page that may not answer: each question
/// once, with each option's label, its mark and its note, and no control, no
/// Other field and no Send. The observer's session page draws this in the card
/// the operator's page answers from, so both read the same questions.
///
/// ## Examples
///
/// ```gleam
/// // attention_thread.questions_only(ask)
/// ```
pub fn questions_only(ask: attention.Ask) -> Element(message) {
  html.div([attribute.class("inbox-questions")], list.map(ask.questions, held))
}

/// One question for a reader who may not answer it. A kind with options lists
/// them, and a kind without says in fixed words what the owner would give.
fn held(question: Question) -> Element(message) {
  html.fieldset([attribute.class("inbox-question")], [
    html.legend([attribute.class("inbox-label")], [html.text(question.prompt)]),
    ..case question.kind, question.options {
      attention.Confirm, _ -> [held_line("Yes or no")]
      attention.Fill(..), _ -> [held_line("A written answer")]
      attention.Choice, options
      | attention.Multiple(..), options
      | attention.Checklist, options
      -> list.map(options, held_option)
    }
  ])
}

/// One option as text: its label, the model's mark when it recommends it, and
/// its note under the label, in the same places the form's options use.
fn held_option(option: attention.Alternative) -> Element(message) {
  html.div([attribute.class("inbox-option inbox-read")], [
    html.span([], [html.text(option.label)]),
    case option.emphasis {
      attention.Recommended ->
        html.em([attribute.class("inbox-mark")], [html.text("recommended")])
      attention.Plain -> element.none()
    },
    case option.note {
      Some(note) ->
        html.small([attribute.class("inbox-note")], [html.text(note)])
      None -> element.none()
    },
  ])
}

/// A line that says what kind of answer a question without options takes.
fn held_line(words: String) -> Element(message) {
  html.p([attribute.class("inbox-hold")], [html.text(words)])
}

/// One question with its component, chosen by the question's kind.
fn question(question: Question) -> Element(message) {
  html.fieldset([attribute.class("inbox-question")], [
    html.legend([attribute.class("inbox-label")], [html.text(question.prompt)]),
    ..case question.kind {
      attention.Confirm -> [
        radio(question, answer_rule.yes, "Yes", None),
        radio(question, answer_rule.no, "No", None),
        other_option("radio", question),
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
          [other_option("radio", question)],
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
    [other_option("checkbox", question)],
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

/// The Other control of a question: one option, drawn as the others are, whose
/// text field is inside it. Choosing the option is what reveals the field (the
/// stylesheet shows it while the option's control is checked), so Other is one
/// control and not an option beside a field. `kind` is the control's type, a
/// radio for a question that takes one answer and a checkbox for one that takes
/// several.
fn other_option(kind: String, question: Question) -> Element(message) {
  html.label([attribute.class("inbox-option")], [
    html.input([
      attribute.type_(kind),
      attribute.name(answer_rule.field_name(question)),
      attribute.value(answer_rule.other),
    ]),
    html.span([], [html.text("Other")]),
    other_field(question),
  ])
}

/// The Other text of a question.
fn other_field(question: Question) -> Element(message) {
  html.input([
    attribute.type_("text"),
    attribute.name(answer_rule.other_name(question)),
    attribute.class("composer-name inbox-other"),
    attribute.aria_label("Other"),
    attribute.placeholder("Write your own answer"),
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

  parts.section("Noticed along the way", [
    parts.quote(
      "The agent noticed ("
        <> attention.find_kind_name(find.kind)
        <> "), untrusted text",
      text,
    ),
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
        html.div([attribute.class("inbox-acts")], [
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
      attribute.class("inbox-btn"),
      event.on_click(acting.close(closure)),
    ],
    [html.text(label)],
  )
}

/// A stuck strand's body: a card of what the page knows, as the final design's
/// rows (the strand's status in the words its reason code gets, and its
/// parent), then the Retry. The status holds the failure time as the browser's
/// clock and says what the provider said about a retry, and never guesses at a
/// time the record lacks.
fn stuck_body(
  stuck: attention_feed.Stuck,
  offer: Offer(message),
) -> Element(message) {
  let failure = thread_words.kind_of(stuck.reason)

  let status = [
    #(
      "Strand status",
      element.fragment(
        phrase.view(thread_words.stuck_phrase(
          failure,
          stuck.failed_at,
          stuck.retry_after_ms,
        )),
      ),
    ),
  ]

  element.fragment([
    parts.section("What the page knows", [
      parts.facts(case stuck.parent {
        Some(parent) -> list.append(status, [#("Parent", html.text(parent))])
        None -> status
      }),
    ]),
    stuck_decide(offer),
  ])
}

/// The stuck strand's Retry, or the words that say who can press it.
fn stuck_decide(offer: Offer(message)) -> Element(message) {
  parts.section("Send it a nudge", [
    case offer.acting {
      Some(acting) ->
        html.div([attribute.class("inbox-acts")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("inbox-btn"),
              event.on_click(acting.retry),
            ],
            [html.text("Retry the last step")],
          ),
        ])
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
      parts.section("Message this session", [
        html.form(
          [
            attribute.class("inbox-form"),
            event.on("submit", note_of(acting.note)) |> event.prevent_default,
          ],
          [
            html.textarea(
              [
                attribute.name("draft"),
                attribute.class("inbox-ta"),
                attribute.aria_label("Message this strand"),
                // The strand is in the eyebrow as text, and no attribute carries
                // a name a session chose.
                attribute.placeholder("Message this strand"),
                attribute.attribute("rows", "3"),
              ],
              "",
            ),
            html.div([attribute.class("inbox-acts")], [
              html.button(
                [attribute.type_("submit"), attribute.class("inbox-btn")],
                [html.text("Stage the message")],
              ),
            ]),
          ],
        ),
      ])
  }
}

/// The outbox bar at the pane's foot: what is staged and to whom, the refusal or
/// the outcome in fixed words, and the buttons. A page that may not act draws
/// nothing.
fn outbox(offer: Offer(message)) -> Element(message) {
  // A page that may not act has no outbox.
  case offer.acting {
    None -> element.none()
    Some(acting) -> {
      let state = offer.state

      // The staged answer's lines come first and the staged note follows.
      let chips =
        list.append(staged_answer(state), case state.outbox.note {
          Some(text) -> ["Message: " <> text]
          None -> []
        })

      // The bar says what the send is doing, or what the daemon answered.
      let said = case state.progress {
        item_pane.Resting -> ""
        item_pane.Sending -> "Sending…"
        item_pane.Settled(words:) -> words
      }

      parts.outbox_bar(
        case state.progress, chips {
          item_pane.Settled(_), _ -> "Sent."
          _, [] -> "Not sent."
          _, _ ->
            "To "
            <> offer.session_name
            <> " · "
            <> int.to_string(list.length(chips))
            <> " staged."
        },
        case chips, said {
          [], "" -> "Nothing is staged. Nothing is sent until you press Send."
          _, words -> words
        },
        chips,
        html.div([attribute.class("inbox-outbox-buttons")], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("inbox-btn"),
              attribute.disabled(!item_pane.has_staged(state)),
              event.on_click(acting.unstage),
            ],
            [html.text("Clear")],
          ),
          html.button(
            [
              attribute.type_("button"),
              attribute.class("inbox-primary"),
              attribute.disabled(
                !item_pane.has_staged(state)
                || state.progress == item_pane.Sending,
              ),
              event.on_click(acting.send),
            ],
            [html.text("Send")],
          ),
        ]),
      )
    }
  }
}

/// The staged answer's lines.
fn staged_answer(state: State) -> List(String) {
  case state.outbox.answer {
    Some(staged) -> staged.lines
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
/// what it wants, as a raised card of keys and values under the label "What it
/// asks for". It decides nothing and carries no handler. Every word of it is a
/// text node, since the preview is the call's own arguments and the reason and
/// details come from a policy a model's call tripped.
///
/// ## Examples
///
/// ```gleam
/// // attention_thread.evidence(approval_evidence.Unseen("not answered"))
/// ```
pub fn evidence(seen: Seen) -> Element(message) {
  case seen {
    approval_evidence.Unseen(words:) ->
      html.p([attribute.class("inbox-meta")], [html.text(words)])
    approval_evidence.Seen(evidence: read) ->
      parts.section(
        "What it asks for",
        list.flatten([
          list.map(read.items, approval_item),
          [more_pending(read)],
          [
            html.p([attribute.class("inbox-meta")], [
              html.text(case approval_evidence.oldest_raised(read) {
                Some(_) -> "It is decided on the session's page."
                None ->
                  "The record carries no time, so no age is shown. It is decided on the session's page."
              }),
            ]),
          ],
        ]),
      )
  }
}

/// The title of an approval's thread, composed from the evidence the page read:
/// `May this program run <command> with write access to <path>?` when a write
/// grant is wanted, and `May <tool> reach the network?` for a network grant. The
/// command, the path and the tool are text a model's call carried, so each is a
/// text node, in `<code>` where the final design draws code, and none reaches an
/// attribute. An approval that wants neither, or whose evidence was not read, has
/// no composed title and the page uses its own sentence.
///
/// ## Examples
///
/// ```gleam
/// assert attention_thread.approval_title(approval_evidence.Unseen("not answered")) == None
/// ```
pub fn approval_title(seen: Seen) -> Option(List(Element(message))) {
  case seen {
    approval_evidence.Unseen(..) -> None
    approval_evidence.Seen(evidence: read) ->
      case read.items {
        [first, ..] -> composed_title(first)
        [] -> None
      }
  }
}

/// The title one pending approval composes, or nothing when it wants no grant the
/// final design words.
fn composed_title(
  item: approval_evidence.Item,
) -> Option(List(Element(message))) {
  let write =
    list.find(item.wanted, fn(grant) { grant.kind == "writable_root" })
  let network = list.find(item.wanted, fn(grant) { grant.kind == "network" })

  // A write grant is worded first, since it names the place the call may change.
  case write, network, item.preview {
    Ok(grant), _, Some(command) ->
      Some([
        html.text("May this program run "),
        html.code([], [html.text(command)]),
        html.text(" with write access to "),
        html.code([], [html.text(grant.detail)]),
        html.text("?"),
      ])
    Ok(grant), _, None ->
      Some([
        html.text("May this program have write access to "),
        html.code([], [html.text(grant.detail)]),
        html.text("?"),
      ])
    Error(Nil), Ok(_), _ ->
      Some([
        html.text("May "),
        html.code([], [
          html.text(case item.tool {
            "" -> "this program"
            tool -> tool
          }),
        ]),
        html.text(" reach the network?"),
      ])
    Error(Nil), Error(Nil), _ -> None
  }
}

/// One pending approval's rows: the tool, the action, what held the call and
/// what it wants.
fn approval_item(item: approval_evidence.Item) -> Element(message) {
  parts.facts(
    list.flatten([
      [
        #(
          "Tool",
          html.code([], [
            html.text(case item.tool {
              "" -> "not recorded"
              tool -> tool
            }),
          ]),
        ),
      ],
      case item.preview {
        Some(preview) -> [#("Command", html.code([], [html.text(preview)]))]
        None -> []
      },
      case item.reason {
        "" -> []
        reason -> [
          #("Held by", html.text(held_by(item.source) <> ": " <> reason)),
        ]
      },
      network_row(item.network),
      wanted_rows(item.wanted),
      policy_row(item.policy),
    ]),
  )
}

/// The network the call would have if it were approved, in the daemon's word
/// for it. The daemon leaves the word out when it cannot be exact, and then the
/// page draws no row: it never words `off` itself.
fn network_row(
  network: Option(approval_evidence.Network),
) -> List(#(String, Element(message))) {
  case network {
    Some(approval_evidence.NetworkOn) -> [#("Network", html.text("on"))]
    Some(approval_evidence.NetworkOff) -> [#("Network", html.text("off"))]
    None -> []
  }
}

/// The sandbox and network the session runs its tools under today, in the
/// daemon's words, such as `workspace-write · network off`. Nothing when the
/// daemon lent no policy.
fn policy_row(
  policy: Option(approval_evidence.Policy),
) -> List(#(String, Element(message))) {
  case policy {
    Some(approval_evidence.Policy(sandbox:, network:)) -> [
      #(
        "Policy today",
        html.code([], [html.text(sandbox <> " · network " <> network)]),
      ),
    ]
    None -> []
  }
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
fn wanted_rows(
  wanted: List(approval_evidence.Wanted),
) -> List(#(String, Element(message))) {
  let #(networks, others) =
    list.partition(wanted, fn(grant) { grant.kind == "network" })

  list.flatten([
    case networks {
      [] -> []
      [_, ..] -> [
        #(
          "Wants a network grant",
          html.text(string.join(
            list.map(networks, fn(grant) { grant.detail }),
            ", ",
          )),
        ),
      ]
    },
    case others {
      [] -> []
      [_, ..] -> [
        #(
          "Wants",
          html.div(
            [],
            list.map(others, fn(grant) {
              html.div([], [html.text(grant.kind <> " " <> grant.detail)])
            }),
          ),
        ),
      ]
    },
  ])
}

/// A line for the pending approvals the reply did not carry.
fn more_pending(read: approval_evidence.Evidence) -> Element(message) {
  case read.count - list.length(read.items) {
    left if left > 0 ->
      html.p([attribute.class("inbox-meta")], [
        html.text(int.to_string(left) <> " more pending, decided on the page."),
      ])
    _ -> element.none()
  }
}
