//// The parts every thread of Home's inbox is drawn from: the group band, the
//// two-line row, the kind chip, the reading pane's frame and the outbox bar at
//// its foot.
////
//// The inbox draws threads from four places: the running sessions
//// (`view/inbox`), the asks, finds and stuck strands of the attention feed
//// (`view/attention_thread`), the review of a finished session
//// (`view/review_thread`) and the project tickets that wait on a person
//// (`view/ticket_thread`), and a saved session's row is a fifth. The final
//// design (`docs/design-notes/attention-inbox/final/mockup.html`) draws all of
//// them as one list and one pane, so the shapes are written once here and each
//// module calls them with its own words. A change to a row's look is a change
//// to this module and the stylesheet's `inbox` section, and to no other.
////
//// A **row** has two lines. The first is a status dot, the session's or
//// strand's name, and an age at the right when the data has one. The second is
//// a small bordered chip with the kind's word and the one-line head, cut with
//// an ellipsis. A thread that is a button (`row`) and a saved session's, which
//// holds a button of its own and so cannot be one (`static_row`), share the
//// two lines (`lines`), so they cannot drift apart.
////
//// A **band** is the heading of a group across the list: the group's name and
//// count at the left, in small capitals, and a plain-case gloss at the right.
//// The group that waits on the owner is tinted with the signal colour.
////
//// A **pane** is a scrolling body and, below it, an outbox bar that stays at
//// the foot of the pane whatever the body's length. The body's parts are the
//// eyebrow (a kind chip and quiet words), the title, small-caps section labels,
//// a raised card of facts and the dashed quote that holds a session's own
//// words under a label saying whose they are.
////
//// Every function takes strings and elements and decides nothing. A name, a
//// head or a quote is the caller's text, drawn as a text node: no class,
//// attribute or key is built from it. The classes are complete literals, so
//// Tailwind finds them.
////
//// ## Flow
////
//// `band` → `row` / `static_row` → `lines`, and `pane` → `outbox_bar`
////
//// 1. `band` draws a group's heading, and `group` the section around it.
//// 2. `row` draws a thread's button and `static_row` a saved one's box, each
////    through `lines`.
//// 3. `pane` places a body over an outbox bar, and `outbox_bar` draws the bar's
////    two halves: what is staged and the one button that sends it.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

/// What a row's dot says about its thread.
pub type Dot {
  /// The thread waits on the owner: an approval, an ask, a ticket.
  Waiting

  /// The thread is open and active: a finished session to read, a running one.
  Running

  /// The thread stopped on a failure.
  Failing

  /// The thread waits on no one: a find, an update, a saved session.
  Resting
}

/// Whether a row is the one whose pane is open.
pub type Selection {
  /// The pane shows this row's thread.
  Selected

  /// Another thread, or none, is shown.
  Unselected
}

/// Whether a band is tinted as the group that waits on the owner.
pub type Tint {
  /// The signal colour: "Needs you".
  Signal

  /// The page's own colour.
  Plain
}

/// How long a thread has waited, as the row's first line says it.
pub type Age {
  Age(
    /// The words: "1h 22m", "40m".
    words: String,
    /// Whether the wait is long enough for the row to mark it.
    standing: Standing,
  )
}

/// Whether a wait is one the owner should notice.
pub type Standing {
  /// An ordinary wait, in the quiet colour.
  Ordinary

  /// A long wait on the owner, in the signal colour and semibold.
  Overdue
}

/// What a row says. The strings are text a person or a session wrote, drawn as
/// text nodes.
pub type Facts {
  Facts(
    /// The status dot's meaning.
    dot: Dot,
    /// The session's or strand's name, in the first line.
    name: String,
    /// How long the thread has waited, when the data says. A thread whose data
    /// holds no time draws none: the page never invents an age.
    age: Option(Age),
    /// The kind's word in the chip: "Approval", "Ask", "Review".
    kind: String,
    /// The one-line head, cut with an ellipsis by the stylesheet.
    head: String,
    /// Whether the row's pane is open.
    selection: Selection,
  )
}

/// A group's heading across the list: `title` and the count, when it has one,
/// at the left, in small capitals, and the plain-case `gloss` at the right.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.band("Needs you", Some(4), "agents stopped for you", inbox_parts.Signal)
/// ```
pub fn band(
  title: String,
  count: Option(Int),
  gloss: String,
  tint: Tint,
) -> Element(message) {
  html.h3(
    [
      attribute.class("inbox-band"),
      attribute.class(case tint {
        Signal -> "inbox-band-signal"
        Plain -> "inbox-band-plain"
      }),
    ],
    [
      html.span([], [
        html.text(title),
        case count {
          Some(count) ->
            html.span([attribute.class("inbox-count")], [
              html.text(" · " <> int.to_string(count)),
            ])
          None -> element.none()
        },
      ]),
      html.small([], [html.text(gloss)]),
    ],
  )
}

/// A group: its band over its rows.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.group(inbox_parts.band("Finds", Some(1), "noticed outside the task", inbox_parts.Plain), rows)
/// ```
pub fn group(
  heading: Element(message),
  rows: List(Element(message)),
) -> Element(message) {
  html.section([attribute.class("inbox-group")], [
    heading,
    html.ul([attribute.class("inbox-threads")], rows),
  ])
}

/// A thread's row: a button that sends `press`.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.row(facts, Picked)
/// ```
pub fn row(facts: Facts, press: message) -> Element(message) {
  html.li([], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("inbox-row"),
        selected_class(facts.selection),
        event.on_click(press),
      ],
      lines(facts),
    ),
  ])
}

/// A row that is not a button, for a thread whose row holds a button of its
/// own: a saved session's, whose one action is to resume it. `extra` is drawn
/// under the two lines.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.static_row(facts, [resume_button])
/// ```
pub fn static_row(
  facts: Facts,
  extra: List(Element(message)),
) -> Element(message) {
  html.li([], [
    html.div(
      [
        attribute.class("inbox-row inbox-row-static"),
        selected_class(facts.selection),
      ],
      list.append(lines(facts), extra),
    ),
  ])
}

/// The two lines of a row. The first is the dot, the name and the age. The
/// second is the kind's chip and the head.
fn lines(facts: Facts) -> List(Element(message)) {
  [
    html.span([attribute.class("inbox-r1")], [
      html.span([attribute.class("inbox-dot"), dot_class(facts.dot)], []),
      html.span([attribute.class("inbox-name")], [html.text(facts.name)]),
      case facts.age {
        Some(Age(words:, standing:)) ->
          html.span(
            [
              attribute.class("inbox-age"),
              case standing {
                Ordinary -> attribute.none()
                Overdue -> attribute.class("inbox-age-overdue")
              },
            ],
            [html.text(words)],
          )
        None -> element.none()
      },
    ]),
    html.span([attribute.class("inbox-r2")], [
      kind_chip(facts.kind),
      html.span([attribute.class("inbox-head")], [html.text(facts.head)]),
    ]),
  ]
}

/// The class that says what a dot means.
fn dot_class(dot: Dot) -> attribute.Attribute(message) {
  attribute.class(case dot {
    Waiting -> "inbox-dot-waiting"
    Running -> "inbox-dot-running"
    Failing -> "inbox-dot-failing"
    Resting -> "inbox-dot-resting"
  })
}

/// The class that marks the row whose pane is open.
fn selected_class(selection: Selection) -> attribute.Attribute(message) {
  case selection {
    Selected -> attribute.class("inbox-selected")
    Unselected -> attribute.none()
  }
}

/// The small bordered chip that names a thread's kind.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.kind_chip("Approval")
/// ```
pub fn kind_chip(word: String) -> Element(message) {
  html.span([attribute.class("inbox-kind")], [html.text(word)])
}

/// The quiet line the rail's folded group is: the word "Quiet", the names of the
/// sessions in it and their count. They have nothing to open, so it is text.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.folded("Quiet", ["docs/threat-model"])
/// ```
pub fn folded(label: String, names: List(String)) -> Element(message) {
  html.p([attribute.class("inbox-folded")], [
    html.b([], [html.text(label)]),
    html.span([attribute.class("inbox-folded-names")], [
      html.text(join(names)),
    ]),
    html.span([attribute.class("inbox-folded-count")], [
      html.text(int.to_string(list.length(names))),
    ]),
  ])
}

/// The names joined by a comma and a space, which is how the folded line lists
/// them.
fn join(names: List(String)) -> String {
  case names {
    [] -> ""
    [only] -> only
    [first, ..rest] -> first <> ", " <> join(rest)
  }
}

/// How the pane is shown on a narrow screen, where the list is the page.
pub type Opening {
  /// The page chose the thread because none was pressed. The pane stays hidden
  /// on a narrow screen until the owner presses a row.
  ByDefault

  /// The owner pressed a row, so the pane covers the list.
  ByPress
}

/// A reading pane: `body` scrolls, and `outbox` is the bar that stays at the
/// foot. `back` is the press that returns to the list on a narrow screen, which
/// the stylesheet draws there and nowhere else.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.pane(inbox_parts.ByPress, Closed, [title], bar)
/// ```
pub fn pane(
  opening: Opening,
  back: message,
  body: List(Element(message)),
  outbox: Element(message),
) -> Element(message) {
  html.section(
    [
      attribute.class("inbox-reading"),
      attribute.class(case opening {
        ByDefault -> "inbox-reading-default"
        ByPress -> "inbox-reading-pressed"
      }),
    ],
    [
      html.div([attribute.class("inbox-body-text")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("inbox-back"),
            event.on_click(back),
          ],
          [html.text("‹ Inbox")],
        ),
        ..body
      ]),
      outbox,
    ],
  )
}

/// The eyebrow above a thread's title: its kind chip and quiet words that say
/// where it comes from, and, when the data has a time, when it began to wait.
/// `since` is a seam: a thread whose data has no raise time passes `None`.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.eyebrow("Approval", "storage/branch-index-repair · main", None)
/// ```
pub fn eyebrow(
  kind: String,
  meta: String,
  since: Option(String),
) -> Element(message) {
  html.p([attribute.class("inbox-eyebrow")], [
    kind_chip(kind),
    html.span([], [html.text(meta)]),
    case since {
      Some(words) -> html.span([], [html.text("· waiting since " <> words)])
      None -> element.none()
    },
  ])
}

/// The thread's title: 20px, semibold. The words are the thread's head, which a
/// session may have written, so they are a text node.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.title("May this program run sqlite3?")
/// ```
pub fn title(words: String) -> Element(message) {
  html.h1([attribute.class("inbox-title")], [html.text(words)])
}

/// A section: a small-caps label over its parts. The label is the page's own
/// fixed words.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.section("What it asks for", [card])
/// ```
pub fn section(
  label: String,
  parts: List(Element(message)),
) -> Element(message) {
  html.section([attribute.class("inbox-section")], [
    html.h2([attribute.class("inbox-label")], [html.text(label)]),
    ..parts
  ])
}

/// A raised card around `parts`.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.card([html.p([], [html.text("A fact.")])])
/// ```
pub fn card(parts: List(Element(message))) -> Element(message) {
  html.div([attribute.class("inbox-card")], parts)
}

/// A card of key and value rows, the key in quiet words at the left.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.facts([#("Tool", html.text("code_mode"))])
/// ```
pub fn facts(rows: List(#(String, Element(message)))) -> Element(message) {
  card([
    html.table([attribute.class("inbox-kv")], [
      html.tbody(
        [],
        list.map(rows, fn(entry) {
          html.tr([], [
            html.td([], [html.text(entry.0)]),
            html.td([], [entry.1]),
          ])
        }),
      ),
    ]),
  ])
}

/// The dashed box that holds a session's own words. `source` says whose they
/// are and that they are untrusted, in the page's fixed words, and `words` is
/// the text, which is a text node.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.quote("The agent's last message, untrusted text", "Done.")
/// ```
pub fn quote(source: String, words: String) -> Element(message) {
  html.div([attribute.class("inbox-quote")], [
    html.b([attribute.class("inbox-quote-source")], [html.text(source)]),
    html.span([attribute.class("inbox-quote-words")], [html.text(words)]),
  ])
}

/// The bar at the foot of the pane. `to` is what the bar says in its first
/// words ("To storage/branch-index-repair"), `says` what follows them, `staged`
/// the chips of what is staged, and `send` the button that sends it, at the
/// right.
///
/// ## Examples
///
/// ```gleam
/// // inbox_parts.outbox_bar("Not sent.", "A message here is queued.", [], send_button)
/// ```
pub fn outbox_bar(
  to: String,
  says: String,
  staged: List(String),
  send: Element(message),
) -> Element(message) {
  html.div([attribute.class("inbox-outbox-bar")], [
    html.div([attribute.class("inbox-outbox-to"), attribute.role("status")], [
      html.b([], [html.text(to)]),
      html.text(" " <> says),
      case staged {
        [] -> element.none()
        chips ->
          html.div(
            [attribute.class("inbox-outbox-items")],
            list.map(chips, fn(each) {
              html.span([attribute.class("inbox-staged")], [html.text(each)])
            }),
          )
      },
    ]),
    send,
  ])
}
