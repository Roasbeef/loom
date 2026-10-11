//// The messages the site's views can raise.
////
//// Views live in several modules and all produce `Element(Msg)`, so the
//// message type sits in a module of its own to keep the imports acyclic.

/// An explainer figure. The id doubles as the DOM id used by the scroll spy.
pub type FigureId {
  Crash
  Approval
  CodeMode
  Migration
}

/// Everything that can change the page.
pub type Msg {
  /// The URL fragment changed.
  RouteChanged(String)
  /// A documentation file arrived, or failed to.
  DocLoaded(slug: String, body: Result(String, Nil))
  /// The reader chose a step with a button or a click.
  FigureGo(FigureId, Int)
  /// The scroll spy found a different step under the reading line.
  FigureScrolled(FigureId, Int)
  /// Start stepping a figure automatically.
  FigurePlay(FigureId)
  /// Stop automatic stepping.
  FigureStop
  /// The play timer fired for the given generation.
  FigureTick(FigureId, Int)
  /// Open or close the documentation menu on a narrow screen.
  ToggleMenu
  /// Scroll to a section of the landing page.
  JumpTo(String)
  /// A key press the figure does not use.
  Ignore
}

/// The id used in the DOM and in `data-fig` attributes.
pub fn figure_key(id: FigureId) -> String {
  case id {
    Crash -> "crash"
    Approval -> "approval"
    CodeMode -> "code-mode"
    Migration -> "migration"
  }
}

/// The inverse of `figure_key`.
pub fn figure_from_key(key: String) -> Result(FigureId, Nil) {
  case key {
    "crash" -> Ok(Crash)
    "approval" -> Ok(Approval)
    "code-mode" -> Ok(CodeMode)
    "migration" -> Ok(Migration)
    _ -> Error(Nil)
  }
}
