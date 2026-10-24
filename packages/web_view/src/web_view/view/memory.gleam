//// The Session pane's "Memory" section, drawn on the daemon owner's page only
//// (protocol-change/087).
////
//// The section is read-only: a snapshot of what the daemon remembers for this
//// workspace and what each run receives of it. It opens with four counts, then
//// says what each run receives (the `[memory] inject` mode and the size of
//// each file), lists the newest notes with their kind and date, and lists the
//// rules a person approved. It points at the proposals section for what still
//// waits and does not repeat it. A note's body is not in the board, and the
//// section says the agent reads one with `history_search kind=note`.
////
//// There is nothing to press, so no handler is drawn and the section has no
//// path the socket must admit. An observer's page and a member's draw
//// `element.none()` here, and the daemon refuses the read to either on its own
//// account.
////
//// The look is plain: tinted blocks with a hairline border, no left-edge bars
//// and no shadows. Every title, description, rule line and file name comes from
//// a model or from a file a model could shape, so each is a text node. None is
//// an attribute, a class, a key or a handler's message, and the classes are
//// literals chosen from closed sets.

import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import session_view/memory_overview as words

/// The section for the page's board: the overview, that it has not been read,
/// or why it could not be.
///
/// `notice` is the words of the last refusal, empty when there is none.
///
/// ## Examples
///
/// ```gleam
/// // memory_view.view(component.memory_kept(model), component.memory_notice(model))
/// ```
pub fn view(board: Option(words.Board), notice: String) -> Element(message) {
  html.section(
    [
      attribute.class("memory"),
      attribute.id("memory"),
      attribute.aria_label("Memory"),
    ],
    [
      html.h3([attribute.class("session-eyebrow")], [html.text("Memory")]),
      ..list.append(refusal(notice), body(board, notice))
    ],
  )
}

/// The last refusal, in the words the shared record kept. It is an alert, so a
/// screen reader says it when it appears.
fn refusal(notice: String) -> List(Element(message)) {
  case notice {
    "" -> []
    sentence -> [
      html.p([attribute.class("memory-notice"), attribute.role("alert")], [
        html.text(sentence),
      ]),
    ]
  }
}

/// A board that has not been read says so, unless a refusal has said why it
/// has not, since "reading" beside "forbidden" would contradict itself.
fn body(board: Option(words.Board), notice: String) -> List(Element(message)) {
  case board, notice {
    None, "" -> [
      html.p([attribute.class("session-quiet")], [
        html.text(words.loading_words),
      ]),
    ]
    None, _ -> []
    Some(board), _ ->
      list.flatten([
        [tiles(board)],
        receives(board),
        notes(board.notes),
        rules(board.rules),
        queue(board.proposals),
        [
          html.p([attribute.class("memory-files session-quiet")], [
            html.text(words.files_words),
          ]),
        ],
      ])
  }
}

/// The four counts, each a small tinted block with its label beneath its value.
fn tiles(board: words.Board) -> Element(message) {
  html.div(
    [attribute.class("memory-tiles")],
    list.map(words.tiles(board), fn(tile) {
      html.div([attribute.class("memory-tile")], [
        html.span([attribute.class("memory-tile-value")], [html.text(tile.1)]),
        html.span([attribute.class("memory-tile-label")], [html.text(tile.0)]),
      ])
    }),
  )
}

fn heading(label: String) -> Element(message) {
  html.h4([attribute.class("memory-heading")], [html.text(label)])
}

/// Receives helper.
fn receives(board: words.Board) -> List(Element(message)) {
  [
    heading("What each run receives"),
    html.p([attribute.class("memory-mode")], [
      html.text(words.inject_words(board)),
    ]),
    html.p([attribute.class("session-quiet")], [html.text(words.config_words)]),
    html.ul(
      [attribute.class("memory-files-list")],
      list.map(board.receives, fn(file) {
        html.li([reach_class(file.reach)], [
          html.text(words.receives_words(file)),
        ])
      }),
    ),
  ]
}

/// The closed set of classes a file's state may give its row, each a literal,
/// so no state the daemon names can choose one.
fn reach_class(reach: words.Reach) -> attribute.Attribute(message) {
  case reach {
    words.Injected -> attribute.class("memory-file-injected")
    words.NotInjected -> attribute.class("memory-file-idle")
    words.Missing -> attribute.class("memory-file-missing")
    words.Unreadable(..) -> attribute.class("memory-file-unreadable")
    words.UnknownReach(..) -> attribute.class("memory-file-unknown")
  }
}

/// Notes helper.
fn notes(section: words.Section(words.Note)) -> List(Element(message)) {
  [
    heading("Notes"),
    ..case section {
      words.Unavailable(reason:) -> [unavailable("Notes unavailable: ", reason)]
      words.Listed(rows: [], ..) -> [
        html.p([attribute.class("session-quiet")], [
          html.text(words.notes_empty_words),
        ]),
      ]
      words.Listed(rows:, omitted:, ..) ->
        list.flatten([
          [
            html.ul([attribute.class("memory-list")], list.map(rows, note_row)),
          ],
          more(omitted, words.notes_pointer),
          [
            html.p([attribute.class("session-quiet")], [
              html.text(words.body_words),
            ]),
          ],
        ])
    }
  ]
}

/// One note: its kind and date first, with a `legacy` mark for a note written
/// before notes were typed, then its title and description.
fn note_row(note: words.Note) -> Element(message) {
  html.li([attribute.class("memory-row")], [
    html.span([attribute.class("memory-row-head")], [
      html.text(words.note_head(note)),
    ]),
    html.span([attribute.class("memory-row-text")], [
      html.text(words.note_text(note)),
    ]),
  ])
}

/// Rules helper.
fn rules(section: words.Section(words.Rule)) -> List(Element(message)) {
  [
    heading("Approved rules"),
    ..case section {
      words.Unavailable(reason:) -> [
        unavailable("Approved rules unavailable: ", reason),
      ]
      words.Listed(rows: [], ..) -> [
        html.p([attribute.class("session-quiet")], [
          html.text(words.rules_empty_words),
        ]),
      ]
      words.Listed(rows:, omitted:, ..) ->
        list.append(
          [
            html.ul([attribute.class("memory-list")], list.map(rows, rule_row)),
          ],
          more(omitted, words.rules_pointer),
        )
    }
  ]
}

/// Rule row helper.
fn rule_row(rule: words.Rule) -> Element(message) {
  html.li([attribute.class("memory-row")], [
    html.span([attribute.class("memory-row-head")], [
      html.text(words.rule_head(rule)),
    ]),
    html.span([attribute.class("memory-row-text")], [html.text(rule.line)]),
  ])
}

/// The queue is counted here and reviewed in its own section, which is above
/// this one in the pane.
fn queue(waiting: words.Waiting) -> List(Element(message)) {
  [
    heading("Proposals"),
    html.p([attribute.class("memory-queue")], [
      html.text(words.proposals_words(waiting, "the Proposals section above")),
    ]),
  ]
}

/// More helper.
fn more(omitted: Int, pointer: String) -> List(Element(message)) {
  case words.omitted_words(omitted, pointer) {
    "" -> []
    sentence -> [
      html.p([attribute.class("session-quiet")], [html.text(sentence)]),
    ]
  }
}

fn unavailable(lead: String, reason: String) -> Element(message) {
  html.p([attribute.class("memory-unavailable"), attribute.role("alert")], [
    html.text(lead <> reason),
  ])
}
