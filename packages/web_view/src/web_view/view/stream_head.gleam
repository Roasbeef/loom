//// The one-line strip above a session's stream: a dot for the state, the
//// session's name, and the facts a reader wants before reading the rows.
////
//// The live mode (`docs/design-notes/attention-inbox/README.md`, section 2.3)
//// is for watching one session, and the strip says which session and what it
//// is doing without opening a panel: `ws-1a6368 · main · work · running`,
//// then the goal and the context figure when the page has them. It repeats
//// nothing the top bar carries as controls. It is a label, with no handler
//// and no marker, so the strip adds no path to the page socket's admitted
//// set.
////
//// The module decides nothing about the session. `component.stream_head`
//// reads the page's own fields and words them; this module draws them. Every
//// field is text the catalogue, the daemon or the engine wrote, so each is a
//// text node and none reaches an attribute. The dot's colour comes from
//// `Tone`, a closed type, never from the words.
////
//// ## Missing data
////
//// The records the page reads carry no time for a turn. `Head.turn` is the
//// place that time goes: `None` today, which leaves the state's words alone,
//// and `Some("14m")` draws `running, turn 14m` with no other change.
////
//// ## Flow
////
//// `view` draws the strip, `state_words` joins the state and the turn's time,
//// and `fact` draws each remaining fact after a separator.

import gleam/list
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
    /// How long the current turn has run, worded (`14m`). No record the page
    /// reads carries it, so it is `None` today; a later layer fills it and
    /// the strip draws `, turn 14m` after the state.
    turn: Option(String),
    /// The pinned goal in one line (`goal: Ship it · active · 4k of 9k
    /// tokens`), or `None` when no goal is pinned.
    goal: Option(String),
    /// The context figure the top bar shows (`ctx ~2%`), or empty when the
    /// bar has none.
    context: String,
  )
}

/// The strip: the dot, the name in semibold, and the quiet facts after it.
///
/// ## Examples
///
/// ```gleam
/// // stream_head.view(Head("ws-1a6368", "main · loom", Running, "running", None, None, ""))
/// ```
pub fn view(head: Head) -> Element(message) {
  html.div([attribute.class("stream-head")], [
    html.span([attribute.class("stream-dot"), tone_class(head.tone)], []),
    html.b([attribute.class("stream-name")], [html.text(head.name)]),
    html.span([attribute.class("stream-fact")], [html.text(head.place)]),
    fact(state_words(head.state, head.turn)),
    ..list.flatten([
      case head.goal {
        Some(words) -> [fact(words)]
        None -> []
      },
      case head.context {
        "" -> []
        words -> [fact(words)]
      },
    ])
  ])
}

/// The state and, when the page has it, the turn's time: `running, turn 14m`.
///
/// ## Examples
///
/// ```gleam
/// assert stream_head.state_words("running", Some("14m")) == "running, turn 14m"
/// assert stream_head.state_words("idle", None) == "idle"
/// ```
pub fn state_words(state: String, turn: Option(String)) -> String {
  case turn {
    Some(time) -> state <> ", turn " <> time
    None -> state
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
