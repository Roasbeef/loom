//// The agent strip: one card per strand the page lists, drawn in the Strands
//// tab of the strand panel (`view/panel`) on both pages, and the types the
//// component builds it from. It was a row of chips below the heading before
//// the redesign moved it to the right-hand column, and the names of its types
//// and classes (`Strip`, `Chip`, `chip-hit`) are from then; the stylesheet
//// draws each chip as a card.
////
//// A card is a mark, the strand's name and one status line
//// (`session_view/strand_card`) that begins with the state's glyph, and
//// nothing else: the model, the context, the cache's expiry and the elapsed
//// time are figures of one strand's own view (`view/strand_detail`), not of a
//// row in a list. The mark is the cache ring at 34 px when the strand has an
//// outlook, and the strand's avatar, its first letter on a tint of its hue,
//// when it has none. The line names a tool
//// and not its command; the card's `title` holds the whole text for a reader
//// who hovers. A strand that waits on a
//// decision reads `Needs approval`, in the attention colour. The approval
//// card that answers it is drawn in the dock and only for the strand on
//// screen, so the strand's card is a button that focuses the strand, which
//// draws the approval card, and carries no control that decides.
////
//// Each card carries `data-loom-card`, its position among the cards as drawn
//// (the listed chips in order, then the advisor's), a number and never a
//// name. The transcript's dots and tags carry `data-loom-focus` with the
//// same number, and `<loom-shell>` clicks the card that has it, so a control
//// with no handler of its own does what the card does
//// (protocol-change/051, the addendum on the marker relay). `positions` is
//// the one place that numbers them, for the cards and for the lane.
////
//// The component derives a `Strip` when a capture, a usage push or a tick
//// changed something it draws (`component.restripped`), and this module
//// only draws it. Which strands are listed and what each line says is
//// `session_view/agent_roster`'s; which cache outlook may be shown is
//// `session_view/cache_watch`'s. Nothing here decides anything about the
//// session.
////
//// A strand's name and its status line are session content or derived from
//// it, so each is drawn as a text node and never as a class or a key. The one
//// attribute they reach is a card's `title`, the tooltip that holds the
//// command a tool's status line left out: an inert, escaped string that
//// names no handler, link or style (protocol-change/051, the addendum of
//// 2026-10-03 on the right panel). The chips are listed by position rather
//// than keyed by name, and a chip's hue comes from its position among the
//// captured strands, never from its name. Every class is a complete
//// literal, so Tailwind finds it.
////
//// A chip is a button that focuses its strand: the page shows that strand's
//// transcript and addresses it (`component.focus`). Its handler's message is
//// made by the function `view` is given, from the strand's name as the strip
//// was built, so the browser's event names only a path. The chips are the
//// strip's `ul`'s children, and the strip is the panel's second child, which
//// is what `component.strip_path` counts on and the observer's socket admits
//// clicks under
//// (protocol-change/051, the addendum on strand focus).
////
//// Settled strands are the list's last item, a collapsed group below the live
//// cards. The group is a native `details` element, so opening and closing it
//// is the browser's and the server never learns which it is. Each settled
//// strand is a card of the same kind as a live one: a button that focuses the
//// strand, numbered by `positions` after the live cards, so a dot or a tag in
//// the transcript can reach it through the marker relay whether or not the
//// group is open. The relay presses the button with a script `click`, which a
//// closed `details` does not prevent. A card says how the strand ended in
//// words (`Finished`, `Failed`) and carries no duration: the roster's clock
//// for a finished operation keeps running, and the capture holds no instant
//// at which the operation ended, so any figure here would be wrong.
//// Focusing a settled strand makes it the active one, and the roster lists
//// the active strand with the live cards, so the card moves out of the group
//// while it is shown and back when the reader leaves it. The group's open
//// state does not survive its emptying: focusing the only settled strand
//// removes the group, and it is recreated closed when a strand settles again.
////
//// The list's children are keyed by fixed words, `card-<n>`, `advisor` and
//// `settled`, never by a strand's name. The group must stay the same element
//// when a live strand starts or settles, or the browser would close it under
//// the reader; an unkeyed list would hand the group's place to whichever item
//// now sits at its index.
////
//// The types live here rather than in `web_view/component` because the
//// component imports this module to lay the page out, and a module the
//// component imports cannot import the component back.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import session_view/agent_roster
import session_view/agent_view
import session_view/cache_miss
import session_view/strand_card
import session_view/turns

/// One agent chip: the roster's line for a strand, the hue its position
/// gives it, and what may be said about its prompt cache.
pub type Chip {
  Chip(
    /// The roster's line: name, status, activity, elapsed time, context.
    line: agent_roster.Line,
    /// The strand's hue, from its position among the captured strands.
    hue: turns.Hue,
    /// The cache outlook `cache_watch.shown` allows for the strand, with
    /// its label, or `None` when nothing honest can be said.
    cache: Option(#(cache_miss.Outlook, String)),
    /// How long the strand's current operation had run when the strip was
    /// built, in milliseconds (`agent_roster.running_ms`), or `None` when
    /// it has no operation.
    running_ms: Option(Int),
    /// The model the strand runs on, as the capture reported it, or empty
    /// when it did not.
    model: String,
    /// The catalogue's name for the strand's model when it is not the main
    /// strand's, which the card draws under the status. `None` for `main`
    /// itself, for a strand on the main strand's model, and while either
    /// model is unknown, so a card names a model only where it tells the
    /// reader something the heading has not.
    own_model: Option(String),
    /// The tools the strand's current operation ran most recently, oldest
    /// first, as `agent_view` bounds them.
    recent: List(String),
    /// The first line of the strand's latest answer, when it has given one:
    /// what a strand's own view shows under `Recent` when no tool ran.
    answer: Option(String),
  )
}

/// The agent strip: the listed agents in the terminal's order, the advisor
/// in its own place, and the strands that settled out of it.
pub type Strip {
  Strip(
    /// `main`, then every other strand whose state needs watching.
    chips: List(Chip),
    /// The advisor, when the capture holds its strand.
    advisor: Option(Chip),
    /// The settled strands in reverse row order (`agent_roster.Chips`), at most
    /// `settled_limit`.
    settled: List(Chip),
    /// How many settled strands are older than the ones in `settled` and are
    /// named only by this count.
    earlier: Int,
    /// The strand the page shows and addresses, whose chip the strip marks
    /// as the current one (`aria-current`, the `following` class). It is
    /// part of the strip so that moving focus redraws the strip, whose
    /// memo is keyed on the whole value.
    followed: String,
  )
}

/// How many settled strands the group lists as cards. Older ones are a count.
pub const settled_limit = 6

/// How many strands the strip lists as live cards: the listed chips and the
/// advisor's. Settled strands are in their own group and are not counted, so
/// the panel's title and the tab's badge speak of the strands that are
/// running or waiting.
///
/// ## Examples
///
/// ```gleam
/// // panel.view(strip.count(strip), strip.view(strip, focus))
/// ```
pub fn count(strip: Strip) -> Int {
  case strip.advisor {
    Some(_) -> list.length(strip.chips) + 1
    None -> list.length(strip.chips)
  }
}

/// Every live card the strip draws, in the order it draws them: the listed
/// chips, then the advisor's. The settled group's cards are `settled_cards`.
///
/// ## Examples
///
/// ```gleam
/// // strip.cards(strip) == [main_chip, tests_chip, advisor_chip]
/// ```
pub fn cards(strip: Strip) -> List(Chip) {
  case strip.advisor {
    Some(advisor) -> list.append(strip.chips, [advisor])
    None -> strip.chips
  }
}

/// Every settled card the group draws, in the strip's order: the cards which follow
/// the live ones in `positions`.
///
/// ## Examples
///
/// ```gleam
/// // strip.settled_cards(strip) == strip.settled
/// ```
pub fn settled_cards(strip: Strip) -> List(Chip) {
  strip.settled
}

/// The position of each card's strand, by the strand's identity: the number
/// the card carries as `data-loom-card` and a dot or tag for the strand
/// carries as `data-loom-focus`. `main` is always first, so position zero is
/// `main` wherever `main` is listed; the advisor follows the listed chips and
/// the settled group's cards come last.
///
/// The map holds identities, which are the daemon's and never reach the page:
/// a marker holds only the number.
///
/// ## Examples
///
/// ```gleam
/// // dict.get(strip.positions(strip), "main") == Ok(0)
/// ```
pub fn positions(strip: Strip) -> Dict(String, Int) {
  list.append(cards(strip), settled_cards(strip))
  |> list.index_map(fn(chip, position) { #(chip.line.id, position) })
  |> dict.from_list
}

/// The card of the strand the strip marks as current, when it has one.
///
/// ## Examples
///
/// ```gleam
/// // strip.followed_card(strip)
/// ```
pub fn followed_card(strip: Strip) -> Option(Chip) {
  list.find(cards(strip), fn(chip) { chip.line.id == strip.followed })
  |> option.from_result
}

/// The name of the marker attribute on a card, whose value is its position.
/// It is fixed here, and `<loom-shell>` reads the same word.
pub const card_marker = "loom-card"

/// The name of the marker attribute on a control that has no handler and does
/// what a card does: a dot or a tag in the transcript, the breadcrumb's `All
/// strands` and the detail's back link. Its value is a card's position. It is
/// fixed here, and `<loom-shell>` reads the same word.
pub const focus_marker = "loom-focus"

/// The marker a control carries to focus the strand at `position`.
///
/// It holds a number and nothing else: no name, no identity, nothing the
/// session wrote. The control has no handler; `<loom-shell>` hears the click
/// and clicks the card with the same position.
///
/// ## Examples
///
/// ```gleam
/// // strip.focus_attribute(2) == attribute.data("loom-focus", "2")
/// ```
pub fn focus_attribute(position: Int) -> attribute.Attribute(message) {
  attribute.data(focus_marker, int.to_string(position))
}

/// The agent strip: one card per listed strand, the advisor's after them,
/// and the collapsed group of settled strands last.
///
/// Each chip is a button whose click is `focus` applied to the strand's
/// name, so a page's message type decides what a press means. The list is
/// memoized on the strip, which the component rebuilds only when something
/// it draws changed; `focus` is a function of the page and not of the
/// session, so it does not key the memo.
///
/// ## Examples
///
/// ```gleam
/// // strip.view(component.strip(model), FocusRequested)
/// ```
pub fn view(strip: Strip, focus: fn(String) -> message) -> Element(message) {
  use <- element.memo([element.ref(strip)])
  case strip.chips, strip.advisor, strip.settled {
    [], None, [] -> element.none()
    _, _, _ -> {
      let live = list.length(strip.chips)
      let cards =
        list.index_map(strip.chips, fn(chip, position) {
          #(
            "card-" <> int.to_string(position),
            chip_element(chip, position, strip.followed, focus),
          )
        })
      let advisor = case strip.advisor {
        Some(chip) -> [
          #("advisor", chip_element(chip, live, strip.followed, focus)),
        ]
        None -> []
      }
      let first_settled = list.length(cards) + list.length(advisor)

      html.nav(
        [attribute.class("agent-strip"), attribute.aria_label("Agents")],
        [
          keyed.ul(
            [attribute.class("chips")],
            list.flatten([
              cards,
              advisor,
              settled_group(strip, first_settled, focus),
            ]),
          ),
        ],
      )
    }
  }
}

// The settled group, or nothing while no strand has settled. Its cards
// continue the positions the live cards began, so a marker's number names one
// card. The text that says how many strands are older than the ones drawn is
// a list item and not a control.
fn settled_group(
  strip: Strip,
  first: Int,
  focus: fn(String) -> message,
) -> List(#(String, Element(message))) {
  case strip.settled {
    [] -> []
    settled -> {
      let cards =
        list.index_map(settled, fn(chip, offset) {
          chip_element(chip, first + offset, strip.followed, focus)
        })
      let earlier = case strip.earlier {
        0 -> []
        count -> [
          html.li([attribute.class("settled-earlier")], [
            html.text("+" <> int.to_string(count) <> " earlier"),
          ]),
        ]
      }
      let total = list.length(settled) + strip.earlier
      [
        #(
          "settled",
          html.li([attribute.class("settled-group")], [
            html.details([], [
              html.summary([attribute.class("settled-title")], [
                html.text("Settled · " <> int.to_string(total)),
              ]),
              html.ul(
                [attribute.class("chips"), attribute.class("settled-chips")],
                list.append(cards, earlier),
              ),
            ]),
          ]),
        ),
      ]
    }
  }
}

fn chip_element(
  chip: Chip,
  position: Int,
  followed: String,
  focus: fn(String) -> message,
) -> Element(message) {
  let line = chip.line
  html.li(chip_attributes(chip, followed), [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("chip-hit"),
        attribute.data(card_marker, int.to_string(position)),
        ..press_attributes(chip.line.id, followed, focus)
      ],
      [
        ring(chip, Card),
        html.span([attribute.class("chip-text")], [
          html.span([attribute.class("chip-name")], [html.text(line.name)]),
          status(line),
          own_model(chip.own_model),
        ]),
      ],
    ),
  ])
}

// The model of a strand that runs on another one than `main`, as plain quiet
// text. The name is the catalogue's, a text node, and an empty node stands in
// for it so the card's children keep their places either way.
fn own_model(model: Option(String)) -> Element(message) {
  case model {
    Some(name) -> html.span([attribute.class("chip-model")], [html.text(name)])
    None -> element.none()
  }
}

/// A strand's status as a card and its own view draw it: the state's glyph,
/// then the status line, in the state's colour.
///
/// ## Examples
///
/// ```gleam
/// // strip.status(chip.line)
/// ```
pub fn status(line: agent_roster.Line) -> Element(message) {
  html.span([attribute.class("chip-status"), status_class(line.status)], [
    html.span([attribute.class("st"), attribute.aria_hidden(True)], [
      html.text(strand_card.glyph(line.status)),
    ]),
    html.text(strand_card.status_line(line)),
  ])
}

// The chip of the strand the page shows is marked as the current one by its
// ring and, on its button, in words for a screen reader.
fn chip_attributes(
  chip: Chip,
  followed: String,
) -> List(attribute.Attribute(message)) {
  case chip.line.id == followed {
    True -> [
      attribute.class("chip"),
      attribute.class("following"),
      hue_class(chip.hue),
    ]
    False -> [attribute.class("chip"), hue_class(chip.hue)]
  }
}

// The button's handler and its state. The current chip is pressed and still
// carries the handler: focusing the strand already shown changes nothing,
// which is `component.focus`'s to say and cheaper than a second view for a
// chip that a stale browser may still press.
fn press_attributes(
  strand: String,
  followed: String,
  focus: fn(String) -> message,
) -> List(attribute.Attribute(message)) {
  let press = event.on_click(focus(strand))
  case strand == followed {
    True -> [attribute.attribute("aria-current", "true"), press]
    False -> [press]
  }
}

/// Where a ring is drawn, which decides its size.
pub type Size {
  /// On a card in the strand list.
  Card

  /// In a strand's own view, larger.
  Detail
}

/// A card's mark: the cache ring when the strand has an outlook to show, and
/// otherwise the strand's avatar, at the size `size` names.
///
/// A held outlook is a ring whose shape says it, with the state's glyph inside
/// and the outlook's words as its `title`, the same words the strand's own view
/// carries in its Cache row. The words are the engine's literals
/// (`cache_miss.outlook_label`), never a strand's text. A strand with no
/// outlook has nothing for a ring to say, and a hollow one reads as a missing
/// figure, so it draws `avatar` instead. Both are decoration for a screen
/// reader, which has the status line.
///
/// ## Examples
///
/// ```gleam
/// // strip.ring(chip, strip.Card)
/// ```
pub fn ring(chip: Chip, size: Size) -> Element(message) {
  case chip.cache {
    Some(#(cache_miss.Unheld, _)) | None -> avatar(chip.line.name, size)
    Some(#(held, words)) ->
      html.span(
        [
          attribute.class("ring"),
          case size {
            Card -> attribute.class("ring-card")
            Detail -> attribute.class("ring-detail")
          },
          ring_class(held),
          attribute.title(words),
          attribute.aria_hidden(True),
        ],
        [
          html.span([attribute.class("ring-glyph")], [
            html.text(strand_card.glyph(chip.line.status)),
          ]),
        ],
      )
  }
}

/// A strand's avatar: a disc tinted toward its hue with the name's first
/// letter. The letter is a text node, the first grapheme of the name in upper
/// case, and the disc's tint comes from the card's hue class, so nothing a
/// strand wrote reaches an attribute or a class. A name with no grapheme draws
/// `?`.
///
/// ## Examples
///
/// ```gleam
/// // strip.avatar("review-readme-usage", strip.Card) draws the letter R
/// ```
pub fn avatar(name: String, size: Size) -> Element(message) {
  let initial = case string.first(name) {
    Ok(grapheme) -> string.uppercase(grapheme)
    Error(Nil) -> "?"
  }

  html.span(
    [
      attribute.class("avatar"),
      case size {
        Card -> attribute.class("avatar-card")
        Detail -> attribute.class("avatar-detail")
      },
      attribute.aria_hidden(True),
    ],
    [html.text(initial)],
  )
}

/// The class naming how an outlook is drawn: a held head, a held tail, an
/// idle age, or a boundary that has passed. Each is a whole literal, which
/// is what lets Tailwind see it.
///
/// ## Examples
///
/// ```gleam
/// // strip.ring_class(cache_miss.Expired) == attribute.class("ring-elapsed")
/// ```
pub fn ring_class(outlook: cache_miss.Outlook) -> attribute.Attribute(message) {
  case outlook {
    cache_miss.Head(..) -> attribute.class("ring-head")
    cache_miss.Held(..) -> attribute.class("ring-tail")
    cache_miss.Idle(..) -> attribute.class("ring-idle")
    cache_miss.Expired -> attribute.class("ring-elapsed")
    cache_miss.Unheld -> attribute.class("ring-none")
  }
}

/// The class for a strand's hue, from its position: never from its name.
///
/// ## Examples
///
/// ```gleam
/// // strip.hue_class(turns.Sub(0)) == attribute.class("hue-2")
/// ```
pub fn hue_class(hue: turns.Hue) -> attribute.Attribute(message) {
  case hue {
    turns.Primary -> attribute.class("hue-main")
    turns.Advisor -> attribute.class("hue-advisor")
    turns.Sub(index: 0) -> attribute.class("hue-2")
    turns.Sub(index: 1) -> attribute.class("hue-3")
    turns.Sub(index: 2) -> attribute.class("hue-4")
    turns.Sub(index: 3) -> attribute.class("hue-5")
    turns.Sub(..) -> attribute.class("hue-6")
    turns.Unplaced -> attribute.class("hue-none")
  }
}

/// The class that colours a strand's status line, a whole literal chosen from
/// the closed status type: the attention colour for a strand that needs a
/// decision, the danger colour for a failed one, and so on.
///
/// ## Examples
///
/// ```gleam
/// // strip.status_class(agent_view.NeedsInput) == attribute.class("needs-input")
/// ```
pub fn status_class(status: agent_view.Status) -> attribute.Attribute(message) {
  case status {
    agent_view.Working -> attribute.class("running")
    agent_view.Waiting -> attribute.class("waiting")
    agent_view.NeedsInput -> attribute.class("needs-input")
    agent_view.Finished -> attribute.class("done")
    agent_view.Failed -> attribute.class("failed")
    agent_view.Halted -> attribute.class("halted")
    agent_view.Idle | agent_view.Unavailable -> attribute.class("idle")
  }
}
