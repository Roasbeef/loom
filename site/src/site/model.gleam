//// The state of the page.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import site/markdown.{type Block}
import site/msg.{type FigureId}
import site/route.{type Route}

/// A documentation file's loading state.
pub type Loaded {
  Loading
  Failed
  Ready(List(Block))
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
