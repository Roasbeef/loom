//// The strip above a session's stream: a dot for the state, the session's name,
//// and the facts a reader wants before reading the rows.
////
//// The live mode (`docs/design-notes/attention-inbox/README.md`, section 2.3)
//// is for watching one session, and the strip says which session and what it
//// is doing without opening a panel: `ws-1a6368 · main · work · running`, then
//// the goal when the page has one, then the session's figures (the context
//// estimate, the cost and the output speed, `view/figures`) and, at the end, the
//// two chips that say where the agent runs and where its commands run
//// (`view/placement`). The figures and the chips were the top bar's second row;
//// the final design gives every page one 44px bar and puts them here.
////
//// The strip is a label with one exception: the context figure opens a
//// breakdown whose Refresh button has a handler. That handler's path is
//// `component.context_refresh_path`, so the strip's children are fixed in
//// number and order (the dot, the name, the place, the state, the goal or an
//// empty node, the figures, the chips) and the strip is the centre's last
//// child on both pages. The module decides nothing about the session.
//// `component.stream_head` reads the page's own fields and words them; this
//// module draws them. Every field is text the catalogue, the daemon or the
//// engine wrote, so each is a text node and none reaches an attribute. The
//// dot's colour comes from `Tone`, a closed type, never from the words.
////
//// ## The turn's time
////
//// A running turn's age is `Head.turn`: the instant its operation started,
//// which the operation's identity carries (`core/ids.op_id_timestamp_ms`). The
//// strip draws `running, turn 14m` with the age in a `<loom-elapsed since>`
//// (`web_client/elapsed`), so the browser counts it on and the server draws the
//// strip again for nothing but a clock. `None` (no operation, or an identity
//// that does not parse) leaves the state's words alone, and no age is invented.
////
//// ## Flow
////
//// `view` draws the strip, `state` joins the state and the turn's age, and
//// `fact` draws each remaining fact after a separator.

import gleam/int
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// How the strip's dot is coloured: the strand is running, waits on the owner,
/// or is quiet. The page chooses from its own state, so the colour and the
/// words cannot disagree.
pub type Tone {
  /// A turn is running.
  Running

  /// An approval waits on the owner.
  Waiting

  /// Nothing is running and nothing is asked.
  Quiet
}

/// What the strip says.
pub type Head {
  Head(
    /// The session's name, or the first eight characters of its identity when
    /// the catalogue has none.
    name: String,
    /// The strand on screen and the workspace's last segment, `main · loom`.
    place: String,
    /// The dot's colour.
    tone: Tone,
    /// What the strand is doing, in a few words: `running`, `idle`, `waiting
    /// for a decision`.
    state: String,
    /// The instant the current turn's operation started, in Unix milliseconds
    /// (`core/ids.op_id_timestamp_ms`), or `None` when no operation runs. The
    /// strip draws `, turn 14m` after the state and the browser counts it on.
    turn: Option(Int),
    /// The pinned goal in one line (`goal: Ship it · active · 4k of 9k
    /// tokens`), or `None` when no goal is pinned.
    goal: Option(String),
  )
}

/// The strip: the dot, the name in semibold, the quiet facts after it, then the
/// figures and the placement chips the caller drew.
///
/// ## Examples
///
/// ```gleam
/// // stream_head.view(Head("ws-1a6368", "main · loom", Running, "running", Some(1_790_000_000_000), None), figures, chips)
/// ```
pub fn view(
  head: Head,
  figures: Element(message),
  chips: Element(message),
) -> Element(message) {
  html.div([attribute.class("stream-head")], [
    html.span([attribute.class("stream-dot"), tone_class(head.tone)], []),
    html.b([attribute.class("stream-name")], [html.text(head.name)]),
    html.span([attribute.class("stream-fact")], [html.text(head.place)]),
    state(head.state, head.turn),
    case head.goal {
      Some(words) -> fact(words)
      None -> element.none()
    },
    figures,
    chips,
  ])
}

/// The state and, when the page has it, the turn's age: `running, turn 14m`,
/// the age a `<loom-elapsed since>` the browser counts on.
///
/// ## Examples
///
/// ```gleam
/// // stream_head.state("running", Some(1_790_000_000_000))
/// ```
pub fn state(words: String, turn: Option(Int)) -> Element(message) {
  case turn {
    Some(since) ->
      html.span(
        [attribute.class("stream-fact"), attribute.class("stream-sep")],
        [
          html.text(words <> ", turn "),
          element.element(
            "loom-elapsed",
            [
              attribute.attribute("since", int.to_string(since)),
              attribute.attribute("form", "minutes"),
            ],
            [],
          ),
        ],
      )
    None -> fact(words)
  }
}

/// A fact after the first two, led by a dot so the facts read as a line.
fn fact(words: String) -> Element(message) {
  html.span([attribute.class("stream-fact"), attribute.class("stream-sep")], [
    html.text(words),
  ])
}

/// The dot's class, from the closed tone.
fn tone_class(tone: Tone) -> attribute.Attribute(message) {
  attribute.class(case tone {
    Running -> "stream-run"
    Waiting -> "stream-wait"
    Quiet -> "stream-quiet"
  })
}
