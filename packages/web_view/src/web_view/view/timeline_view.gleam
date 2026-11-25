//// Draws a session's timeline: one line for where the session is, and a list of
//// cards for what it did (protocol-change/134,
//// `docs/design-notes/session-timeline.md`, section 6).
////
//// A reader who comes back to a finished session wants the shape of the run
//// before any step of it. A card is one span of the session's records. Its kind
//// word, its time and its numbers are the harness's own, from the records; its
//// command, its paths, the names of the sub-agents it started and the first words
//// of a prompt or an answer are session text. Every one of those is drawn as a
//// text node, with no attribute, class or key from the text.
////
//// ## Flow
////
//// `pane` → `now` → `bar` → `card` → `words` → `chips` → `detail`
////
//// 1. `pane` is the section a thread draws, or nothing when no read has
////    answered.
//// 2. `now` is the open span and `bar` the density control. A card is a button
////    that opens its detail, and `older` asks for the cards before the first.
//// 3. `words` says what a card is about in the harness's words, `chips` states
////    its figures, and `detail` lists its files, children and the way into the
////    transcript.
////
//// ## What it claims
////
//// A command card states the command and its exit status and nothing about what
//// the command meant: an exit status is not a verdict, so none is coloured as a
//// pass, and a failure is tinted.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import session_view/timeline
import web_view/session_brief
import web_view/thread_words
import web_view/timeline_feed.{type Card}
import web_view/timeline_rule.{type Density, type Held}
import web_view/view/inbox_parts as parts
import web_view/view/phrase

/// The messages a timeline's controls send.
pub type Handlers(message) {
  Handlers(
    /// A density was chosen.
    density: fn(Density) -> message,
    /// A card's head was pressed; the number is the card's `from_seq`.
    toggle: fn(Int) -> message,
    /// "Earlier cards" was pressed.
    older: message,
    /// "Open in transcript" was pressed.
    open: message,
  )
}

/// What the section draws from.
pub type Offer(message) {
  Offer(
    /// What the page holds of the session's timeline, or nothing before a read
    /// has answered.
    held: Option(Held),
    density: Density,
    /// The `from_seq` of each card whose detail the person opened.
    opened: Set(Int),
    /// The wall-clock time in Unix milliseconds, which "since" is counted from.
    now: Int,
    handlers: Option(Handlers(message)),
  )
}

/// The timeline section for a thread, or nothing when no read has answered or the
/// session has no card yet.
///
/// ## Examples
///
/// ```gleam
/// // timeline_view.pane(Offer(held: None, density: Landmarks, opened: set.new(), now: 0, handlers: None))
/// ```
pub fn pane(offer: Offer(message)) -> Element(message) {
  // A read that was refused says its fixed words, and one that answered with no
  // card says nothing.
  case offer.held {
    None -> element.none()
    Some(timeline_rule.Held(cards: [], now: None, words: Some(words), ..)) ->
      parts.section("Timeline", [notice(words)])
    Some(timeline_rule.Held(cards: [], now: None, ..)) -> element.none()
    Some(held) ->
      element.fragment([
        now(held, offer.now),
        parts.section("Timeline", [
          bar(offer),
          list_of(held, offer),
          older(held, offer),
        ]),
      ])
  }
}

/// A line of the daemon's own words.
fn notice(words: String) -> Element(message) {
  html.p([attribute.class("timeline-notice")], [html.text(words)])
}

/// Where the session is: the open span, in the harness's figures. Nothing when no
/// span is open.
fn now(held: Held, at: Int) -> Element(message) {
  // The open span is the cards since the last one closed.
  case held.now {
    Some(card) ->
      parts.section("Where it is", [
        html.div([attribute.class("timeline-now")], [
          html.text(
            int.to_string(card.steps)
            <> plural(card.steps, " step", " steps")
            <> " since the last card, last record "
            <> since(int.max(0, at - card.ended_at)),
          ),
        ]),
      ])
    None -> element.none()
  }
}

/// How long ago the last record was, as a phrase that ends the sentence.
fn since(wait: Int) -> String {
  // Under a minute the age word is `now`, which reads badly before `ago`.
  case thread_words.short_age(wait) {
    "now" -> "just now"
    age -> age <> " ago"
  }
}

/// The density control: three buttons, the chosen one pressed.
fn bar(offer: Offer(message)) -> Element(message) {
  // A page that may not choose draws the words without buttons.
  case offer.handlers {
    Some(handlers) ->
      html.div([attribute.class("timeline-density")], [
        density_button(
          offer.density,
          timeline_rule.Landmarks,
          "Landmarks",
          handlers,
        ),
        density_button(
          offer.density,
          timeline_rule.Standard,
          "All cards",
          handlers,
        ),
        density_button(
          offer.density,
          timeline_rule.Detailed,
          "With detail",
          handlers,
        ),
      ])
    None -> element.none()
  }
}

/// One density button, marked as pressed when it is the chosen one.
fn density_button(
  chosen: Density,
  density: Density,
  label: String,
  handlers: Handlers(message),
) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("timeline-density-button"),
      attribute.attribute("aria-pressed", case chosen == density {
        True -> "true"
        False -> "false"
      }),
      event.on_click(handlers.density(density)),
    ],
    [html.text(label)],
  )
}

/// The cards a density shows, as a list, newest last.
fn list_of(held: Held, offer: Offer(message)) -> Element(message) {
  let cards = timeline_rule.shown(held.cards, offer.density)

  // A density that hides every card says so and offers the next one.
  case cards {
    [] -> notice("No landmark yet. Choose All cards to see every span.")
    _ ->
      html.ol(
        [attribute.class("timeline-list")],
        list.map(cards, fn(each) { html.li([], [card(each, offer)]) }),
      )
  }
}

/// One card: its head, which opens it, its chips, and its detail when open.
fn card(each: Card, offer: Offer(message)) -> Element(message) {
  let open =
    set.contains(offer.opened, each.from_seq)
    || offer.density == timeline_rule.Detailed

  html.div(
    [
      attribute.class("timeline-card"),
      attribute.class(case failed(each) {
        True -> "timeline-card-failed"
        False -> "timeline-card-plain"
      }),
    ],
    [
      head(each, offer),
      html.div([attribute.class("timeline-chips")], chips(each)),
      case open {
        True -> detail(each, offer)
        False -> element.none()
      },
    ],
  )
}

/// Whether a card holds a call or a command that failed.
fn failed(each: Card) -> Bool {
  each.failed > 0
}

/// The head of a card: the kind word, the time and the words, a button when the
/// page may open it.
fn head(each: Card, offer: Offer(message)) -> Element(message) {
  let inner = [
    html.span([attribute.class("timeline-kind")], [
      html.text(timeline.kind_word(each.kind)),
    ]),
    html.span([attribute.class("timeline-time")], [phrase.clock(each.ended_at)]),
    html.span([attribute.class("timeline-words")], words(each)),
  ]

  // A page that may not choose draws the head without a handler.
  case offer.handlers {
    Some(handlers) ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("timeline-head"),
          event.on_click(handlers.toggle(each.from_seq)),
        ],
        inner,
      )
    None -> html.div([attribute.class("timeline-head")], inner)
  }
}

/// What a card is about, in the harness's words with session text as text nodes.
fn words(each: Card) -> List(Element(message)) {
  // The kind decides which fact the words state.
  case each.kind {
    timeline.Prompted -> [quoted(each.excerpt)]
    timeline.Answered -> [quoted(each.excerpt)]
    timeline.Ran -> [
      case each.command {
        Some(command) ->
          html.code([], [
            html.text(
              session_brief.untrusted_text(command.text)
              <> " · exit "
              <> int.to_string(command.exit),
            ),
          ])
        None -> html.text("Ran a command")
      },
    ]
    timeline.Worked -> [
      html.text(case each.files_total {
        0 -> int.to_string(each.steps) <> plural(each.steps, " step", " steps")
        total ->
          "Wrote " <> int.to_string(total) <> plural(total, " file", " files")
      }),
    ]
    timeline.Reported -> [html.text("A sub-agent returned")]
    timeline.Asked -> [html.text("Asked a question")]
    timeline.Compacted -> [
      html.text(case each.tokens_before {
        Some(tokens) ->
          "Context compacted, " <> thread_words.tokens(tokens) <> " cut"
        None -> "Context compacted"
      }),
    ]
  }
}

/// The first words of a prompt or an answer, quoted, as a text node.
fn quoted(excerpt: Option(session_brief.Untrusted)) -> Element(message) {
  // A message with no words is drawn as none.
  case excerpt {
    Some(words) -> html.text("“" <> session_brief.untrusted_text(words) <> "”")
    None -> html.text("No words")
  }
}

/// A card's figures, which are numbers from the records.
fn chips(each: Card) -> List(Element(message)) {
  list.flatten([
    case each.steps {
      0 -> []
      steps -> [
        chip(
          int.to_string(steps) <> plural(steps, " step", " steps"),
          "inbox-pill",
        ),
      ]
    },
    case each.files_total {
      0 -> []
      total -> [
        chip(
          int.to_string(total) <> plural(total, " file", " files"),
          "inbox-pill",
        ),
      ]
    },
    case each.failed {
      0 -> []
      count -> [
        chip(int.to_string(count) <> " failed", "inbox-pill inbox-pill-bad"),
      ]
    },
    case each.peers {
      0 -> []
      count -> [
        chip(
          int.to_string(count) <> plural(count, " message", " messages"),
          "inbox-pill",
        ),
      ]
    },
  ])
}

/// One chip of words the page wrote.
fn chip(words: String, class: String) -> Element(message) {
  html.span([attribute.class(class)], [html.text(words)])
}

/// A card's detail: the files it wrote, the sub-agents it started, and the way
/// into the session's own page.
fn detail(each: Card, offer: Offer(message)) -> Element(message) {
  html.div([attribute.class("timeline-detail")], [
    case each.files {
      [] -> element.none()
      files ->
        html.ul(
          [attribute.class("timeline-files")],
          list.map(files, fn(file) {
            html.li([], [
              html.code([], [
                html.text(session_brief.untrusted_text(file.path)),
              ]),
              html.span([attribute.class("timeline-added")], [
                html.text(" +" <> int.to_string(file.added)),
              ]),
              html.span([attribute.class("timeline-removed")], [
                html.text(" −" <> int.to_string(file.removed)),
              ]),
            ])
          }),
        )
    },
    case each.files_total - list.length(each.files) {
      rest if rest > 0 ->
        html.p([attribute.class("timeline-more")], [
          html.text(
            "and "
            <> int.to_string(rest)
            <> plural(rest, " more file", " more files"),
          ),
        ])
      _ -> element.none()
    },
    case each.spawned {
      [] -> element.none()
      children ->
        html.ul(
          [attribute.class("timeline-children")],
          list.map(children, fn(purpose) {
            html.li([], [
              html.text("Started a sub-agent: "),
              html.span([], [html.text(session_brief.untrusted_text(purpose))]),
            ])
          }),
        )
    },
    case offer.handlers {
      Some(handlers) ->
        html.button(
          [
            attribute.type_("button"),
            attribute.class("timeline-open"),
            event.on_click(handlers.open),
          ],
          [html.text("Open the session")],
        )
      None -> element.none()
    },
  ])
}

/// The press that asks for the cards before the first held, when the daemon has
/// more.
fn older(held: Held, offer: Offer(message)) -> Element(message) {
  // Only a page that may press, with a cursor, offers the older cards.
  case held.older, offer.handlers {
    Some(_), Some(handlers) ->
      html.button(
        [
          attribute.type_("button"),
          attribute.class("timeline-older"),
          event.on_click(handlers.older),
        ],
        [html.text("Earlier cards")],
      )
    Some(_), None | None, _ -> element.none()
  }
}

/// A word and its plural by a count.
fn plural(count: Int, one: String, many: String) -> String {
  case count {
    1 -> one
    _ -> many
  }
}
