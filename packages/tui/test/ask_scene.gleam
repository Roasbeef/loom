//// Open asks and the terminal frames that show them, for the ask card's tests.
////
//// An ask is built the way the daemon stores one (`core/attention`), so a test
//// of the form or the card reads the same record `attention.read` would carry.
//// `with_asks` puts forms on a model attached to a session, which the card's
//// rendering tests then paint through `frame_scene`.

import core/attention.{
  Alternative, Anchor, Ask, AskOpen, Checklist, Choice, Confirm, Fill, Header,
  Multiple, Plain, Question, Recommended,
}
import core/clock
import core/ids
import frame_scene
import gleam/list
import gleam/option.{None, Some}
import session_view/shared_set
import tui/ask_board
import tui/ask_form
import tui/model as tui_model
import tui/view_set

/// The session every scene attaches.
pub const session = "fix readme badge"

/// 13:40 UTC on some day, in Unix milliseconds.
pub const thirteen_forty = 49_200_000

fn operation() -> ids.OpId {
  let #(id, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  id
}

fn header(id: String, created_at: Int, strand: String) -> attention.Header {
  Header(
    id:,
    created_at:,
    routing: attention.ToOwner,
    anchor: Anchor(operation: operation(), step_id: "s", source_index: 0),
    strand:,
    parents: [],
  )
}

fn options(labels: List(String)) -> List(attention.Alternative) {
  list.map(labels, fn(label) {
    Alternative(label:, note: None, emphasis: Plain)
  })
}

/// An ask of two questions: a choice with a recommended option and a note, and
/// a confirm.
pub fn choice_ask(id: String, created_at: Int) -> attention.Ask {
  Ask(
    header: header(id, created_at, "main"),
    why: Some("The tree has both layouts and one has to go."),
    questions: [
      Question(
        "q1",
        "Closed items: fold under open ones, or keep a list?",
        Choice,
        [
          Alternative(
            label: "Fold under open ones",
            note: Some("Keeps context together."),
            emphasis: Recommended,
          ),
          Alternative(
            label: "Separate list",
            note: Some("Closed work leaves the page."),
            emphasis: Plain,
          ),
        ],
      ),
      Question("q2", "Keep the independent parts?", Confirm, []),
    ],
    state: AskOpen,
  )
}

/// An ask with one question of every other kind.
pub fn kinds_ask(id: String) -> attention.Ask {
  Ask(
    header: header(id, thirteen_forty, "sub:audit"),
    why: None,
    questions: [
      Question(
        "q1",
        "Which files?",
        Multiple(min: 1, max: 2),
        options(["a", "b", "c"]),
      ),
      Question("q2", "Which checks?", Checklist, options(["fmt", "lint"])),
      Question("q3", "Which path?", Fill(attention.FilePath), []),
    ],
    state: AskOpen,
  )
}

/// A form for an ask the owner may answer, read at revision 41.
pub fn form(ask: attention.Ask) -> ask_form.Form {
  ask_form.new(ask, 41, ask_form.MayAnswer)
}

/// A model attached to `session`, with the local clock at UTC, holding these
/// forms as the ask board's open asks.
pub fn with_asks(forms: List(ask_form.Form), open: Int) -> tui_model.Model {
  let base =
    frame_scene.attach(frame_scene.model(), session, [
      frame_scene.user(1, "Tidy the inbox"),
      frame_scene.assistant(2, "I have a question first.", []),
    ])
  tui_model.Model(
    shared: shared_set.clock_offset(base.shared, Some(0)),
    view: view_set.asks(
      base.view,
      ask_board.Board(..ask_board.empty(), session:, forms:, open:),
    ),
  )
}

/// A form for an ask the owner holds as an observer.
pub fn observer(ask: attention.Ask) -> ask_form.Form {
  ask_form.new(ask, 41, ask_form.ObserverOnly)
}
