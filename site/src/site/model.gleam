//// The state of the page.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import site/markdown.{type Block}
import site/msg.{type Decision, type FigureId, type ShotView}
import site/route.{type Route}

/// A documentation file's loading state.
pub type Loaded {
  Loading
  Failed
  Ready(List(Block))
}

/// Where the landing page's scripted replay is.
pub type Replay {
  Replay(
    /// The step on screen.
    index: Int,
    /// The reader's answer at the approval dialog, once given. The steps
    /// after the dialog differ with it.
    decision: Option(Decision),
    /// Whether the replay is stepping by itself.
    playing: Bool,
    /// Incremented each time playback starts or the reader moves by hand, so
    /// that a timer set earlier is ignored when it fires.
    generation: Int,
    /// Whether the replay has already started once on its own. It does that
    /// only the first time it scrolls into view.
    autostarted: Bool,
  )
}

pub type Model {
  Model(
    route: Route,
    /// The step each figure shows, keyed by `msg.figure_key`.
    steps: Dict(String, Int),
    /// The figure that is stepping by itself, if any.
    playing: Option(FigureId),
    /// Incremented for each Play, so a timer from an earlier Play is ignored.
    play_generation: Int,
    docs: Dict(String, Loaded),
    menu_open: Bool,
    /// The landing page section under the reading line, or an empty string
    /// above the first one.
    section: String,
    /// Whether the "On this page" list is open on a narrow screen.
    contents_open: Bool,
    replay: Replay,
    /// The code sample that shows "Copied", if any.
    copied: Option(String),
    /// Which capture of the terminal client the landing page shows.
    shot_view: ShotView,
  )
}

/// The state of the page when it loads.
pub fn new(current: Route) -> Model {
  Model(
    route: current,
    steps: dict.new(),
    playing: None,
    play_generation: 0,
    docs: dict.new(),
    menu_open: False,
    section: "",
    contents_open: False,
    replay: new_replay(),
    copied: None,
    shot_view: msg.Compact,
  )
}

/// A replay at its first step with nothing answered.
pub fn new_replay() -> Replay {
  Replay(
    index: 0,
    decision: None,
    playing: False,
    generation: 0,
    autostarted: False,
  )
}

/// The step a figure currently shows.
pub fn step(model: Model, id: FigureId) -> Int {
  case dict.get(model.steps, msg.figure_key(id)) {
    Ok(step) -> step
    Error(Nil) -> 0
  }
}

/// Whether this figure is stepping by itself.
pub fn is_playing(model: Model, id: FigureId) -> Bool {
  model.playing == Some(id)
}

/// The loading state of a documentation page.
pub fn doc(model: Model, slug: String) -> Loaded {
  case dict.get(model.docs, slug) {
    Ok(loaded) -> loaded
    Error(Nil) -> Loading
  }
}

/// A model with no figure playing.
pub fn stopped(model: Model) -> Model {
  Model(..model, playing: None)
}
