//// The agent strip: one chip per strand the page lists, drawn below the
//// heading on both pages, and the types the component builds it from.
////
//// The component derives a `Strip` when a capture, a usage push or a tick
//// changed something it draws (`component.restripped`), and this module
//// only draws it. Which strands are listed and what each line says is
//// `session_view/agent_roster`'s; which cache outlook may be shown is
//// `session_view/cache_watch`'s. Nothing here decides anything about the
//// session.
////
//// A strand's name, its activity line and its figures are session content
//// or derived from it, so each is drawn as a text node and never as an
//// attribute, a class or a key. The chips are listed by position rather
//// than keyed by name, and a chip's hue comes from its position among the
//// captured strands, never from its name. Every class is a complete
//// literal, so Tailwind finds it.
////
//// A chip is a button that focuses its strand: the page shows that strand's
//// transcript and addresses it (`component.focus`). Its handler's message is
//// made by the function `view` is given, from the strand's name as the strip
//// was built, so the browser's event names only a path. The chips are the
//// strip's `ul`'s children, which is what `component.strip_path` counts on
//// and the observer's socket admits clicks under
//// (protocol-change/051, the addendum on strand focus). The strip that says
//// "settled" is not a control.
////
//// The types live here rather than in `web_view/component` because the
//// component imports this module to lay the page out, and a module the
//// component imports cannot import the component back.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import session_view/agent_roster
import session_view/agent_view
import session_view/cache_miss
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
  )
}

/// The agent strip: the listed agents in the terminal's order, the advisor
/// in its own place, and how many strands settled out of it.
pub type Strip {
  Strip(
    /// `main`, then every other strand whose state needs watching.
    chips: List(Chip),
    /// The advisor, when the capture holds its strand.
    advisor: Option(Chip),
    /// How many strands settled and left the strip.
    settled: Int,
    /// The strand the page shows and addresses, whose chip the strip marks
    /// as the current one (`aria-current`, the `following` class). It is
    /// part of the strip so that moving focus redraws the strip, whose
    /// memo is keyed on the whole value.
    followed: String,
  )
}

/// The agent strip: one chip per listed strand, the advisor's chip last,
/// and one chip counting the strands that settled.
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
  case strip.chips, strip.advisor {
    [], None -> element.none()
    _, _ -> {
      let settled = case strip.settled {
        0 -> []
        count -> [
          html.li([attribute.class("chip settled")], [
            html.span([attribute.class("chip-name")], [
              html.text("+" <> int.to_string(count) <> " settled"),
            ]),
          ]),
        ]
      }
      let chip_element = chip_element(_, strip.followed, focus)
      let advisor = case strip.advisor {
        Some(chip) -> [chip_element(chip)]
        None -> []
      }

      // Chips are listed by position, never keyed by strand name: a child's
      // name carries words its parent chose.
      html.nav(
        [attribute.class("agent-strip"), attribute.aria_label("Agents")],
        [
          html.ul(
            [attribute.class("chips")],
            list.flatten([list.map(strip.chips, chip_element), settled, advisor]),
          ),
        ],
      )
    }
  }
}

fn chip_element(
  chip: Chip,
  followed: String,
  focus: fn(String) -> message,
) -> Element(message) {
  let line = chip.line
  let figures =
    option.map(line.tokens, fn(count) {
      agent_roster.count_label(count) <> " ctx"
    })
    |> option.to_result(Nil)
    |> result.map(list.wrap)
    |> result.unwrap([])
  html.li(chip_attributes(chip, followed), [
    html.span([attribute.class("swatch"), attribute.aria_hidden(True)], []),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("chip-hit"),
        ..press_attributes(chip.line.id, followed, focus)
      ],
      [
        html.span([attribute.class("chip-head")], [
          html.span([attribute.class("chip-name")], [html.text(line.name)]),
          html.span([attribute.class("state"), status_class(line.status)], [
            html.span([attribute.class("glyph"), attribute.aria_hidden(True)], [
              html.text(status_glyph(line.status)),
            ]),
            html.text(agent_view.label(line.status)),
          ]),
        ]),
        html.span([attribute.class("chip-activity")], [html.text(line.text)]),
        html.span([attribute.class("chip-figures")], [
          elapsed(chip),
          html.text(string.join(figures, " · ")),
          ring(chip.cache),
        ]),
      ],
    ),
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

// How long the strand's operation has run. The browser counts it
// (`<loom-elapsed>`, from `packages/web_client`), so the server never
// renders again only to move a clock. The attribute is a duration the
// roster measured on the daemon host's clock, and the element anchors it to
// the browser's clock when it arrives: an instant from one clock is never
// subtracted from the other, so a browser whose clock is off by a minute
// still counts right. A rebuilt strip carries a fresh reading, which
// re-anchors the count.
fn elapsed(chip: Chip) -> Element(message) {
  case chip.running_ms {
    Some(running) ->
      element.element(
        "loom-elapsed",
        [
          attribute.class("elapsed"),
          attribute.attribute("offset", int.to_string(running)),
        ],
        [],
      )
    None -> element.none()
  }
}

// The cache ring: its shape from the outlook, its words from
// `cache_miss.outlook_label`, which is all the outlook may claim and is
// never session text. The words are drawn beside the ring rather than kept
// in a tooltip. A strand whose outlook is shown is resting, so its chip has
// no elapsed time and usually no context size, and a ring on its own read
// as a stray glyph; with its words it reads as the cache's state. The ring
// is then decoration, hidden from a screen reader, which reads the words.
fn ring(cache: Option(#(cache_miss.Outlook, String))) -> Element(message) {
  case cache {
    None -> element.none()
    Some(#(held, label)) ->
      html.span([attribute.class("cache")], [
        html.span(
          [
            attribute.class("ring"),
            ring_class(held),
            attribute.aria_hidden(True),
          ],
          [],
        ),
        html.text(label),
      ])
  }
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

fn status_class(status: agent_view.Status) -> attribute.Attribute(message) {
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

// The glyph beside every state label; colour never carries state alone.
fn status_glyph(status: agent_view.Status) -> String {
  case status {
    agent_view.Working -> "●"
    agent_view.Waiting -> "◌"
    agent_view.NeedsInput -> "◇"
    agent_view.Finished -> "✓"
    agent_view.Failed -> "✕"
    agent_view.Halted -> "⊘"
    agent_view.Idle | agent_view.Unavailable -> "○"
  }
}
