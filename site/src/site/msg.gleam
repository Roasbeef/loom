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

/// What the visitor can answer at the replay's approval dialog.
pub type Decision {
  AllowOnce
  AllowSession
  Deny
}

/// How much of a tool call the terminal screenshot shows: the default
/// collapsed card, or the details expanded with Ctrl+G.
pub type ShotView {
  Compact
  Expanded
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
  /// The section spy found a different section under the reading line.
  SectionScrolled(String)
  /// Open or close the "On this page" list on a narrow screen.
  ToggleContents
  /// The reader chose a replay step with a button, a chip or an arrow key.
  ReplayGo(Int)
  /// Start the replay stepping by itself. At the end, this starts it over.
  ReplayPlay
  /// Stop the replay stepping by itself.
  ReplayPause
  /// The replay's timer fired for the given generation.
  ReplayTick(Int)
  /// Start the replay again from its first step, with no answer recorded.
  ReplayRestart
  /// The reader answered the approval dialog.
  ReplayDecide(Decision)
  /// The replay scrolled into view for the first time.
  ReplayVisible
  /// Show a step of a figure: set it, then scroll the figure into view.
  ShowFigure(FigureId, Int)
  /// Copy a code sample to the clipboard.
  CopyText(id: String, text: String)
  /// A copy finished. The id names the sample that gets its "Copied" label.
  CopyDone(String)
  /// The "Copied" label of a sample has been up long enough.
  CopyReset(String)
  /// The reader chose the collapsed or the expanded terminal screenshot.
  ShotViewChosen(ShotView)
  /// A key press that nothing uses.
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
