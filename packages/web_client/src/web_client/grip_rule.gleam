//// What `<loom-shell>` decides about the width of the strand panel: how far a
//// drag moves it, what the arrow keys do to it, and how large it may grow.
////
//// The panel is the frame's right column, 340 px wide until the reader
//// changes it. A Changes diff or a Trace row is wider than that, so the shell
//// draws a grip on the column's left edge, and the reader drags it left to
//// widen the panel or right to narrow it. The grip is also a keyboard control
//// (`adjustment`), because a pointer is not the only way to resize a window
//// and the ARIA window-splitter pattern asks for one.
////
//// Three numbers bound the width. The panel never goes under `least_width`,
//// which keeps the tab bar readable. It never takes the transcript below
//// `centre_floor`, which is the same floor the stylesheet gives the centre
//// column, so a drag cannot squeeze the conversation to nothing. And a width
//// read back from storage is never above `most_width`, so a stored value that
//// something else wrote cannot ask for a panel wider than any screen. The
//// second bound depends on the window, so the shell measures how much room
//// there is when a gesture starts (`Room`) and this module turns the
//// measurement into a ceiling.
////
//// The module decides and does not act. It imports neither Lustre nor the DOM
//// binding, so the tests load it under Node, and it stores nothing: where the
//// width is kept is `web_client/layout_rule`'s concern.
////
//// ## Flow
////
//// `ceiling` → `begin` → `dragged`, and `adjustment` → `adjusted`
////
//// 1. `ceiling` is the widest the panel may be in the room that was measured.
//// 2. `begin` records where a drag started, how wide the panel was then and
////    the ceiling, so every later move is computed from the start and a pointer
////    that wanders past a limit and comes back has no dead zone.
//// 3. `dragged` is the width for the pointer's current position.
//// 4. `adjustment` decodes a key press on the grip, and `adjusted` applies it.

import gleam/int
import gleam/option.{type Option, None, Some}
import web_client/shell_rule.{type Modifier, Free, Held}

/// The panel's width before the reader changes it, in pixels. The stylesheet's
/// fallback for the `--panel-width` property is the same number.
pub const default_width = 340

/// The narrowest the panel may be, in pixels: room for the four tabs.
pub const least_width = 280

/// The least width the transcript keeps, in pixels. The stylesheet gives the
/// centre column this `min-width` where the panel is a column, so the browser
/// and this module agree on where a drag stops.
pub const centre_floor = 360

/// The widest stored width this release accepts, in pixels. It is a sanity
/// bound on text that came from storage and not a layout rule: the ceiling in
/// the window at hand is always the tighter of the two.
pub const most_width = 4000

/// How far an arrow key moves the panel, in pixels.
pub const fine_step = 24

/// How far an arrow key moves the panel while Shift is held, in pixels.
pub const coarse_step = 96

/// How wide the panel and the transcript were when a gesture began, as the
/// browser laid them out. The two together are the room the pair shares, which
/// is what a resize redistributes.
pub type Room {
  Room(panel: Int, centre: Int)
}

/// A drag in progress. It holds the three facts the width is computed from.
pub type Drag {
  Drag(
    /// The pointer's horizontal position when the drag began.
    origin: Int,
    /// The panel's width when the drag began.
    start: Int,
    /// The widest the panel may be for this drag.
    ceiling: Int,
  )
}

/// Whether a pointer button was down at the moment of a move.
pub type Contact {
  /// A button was down: the drag continues.
  Pressing

  /// No button was down: the release was missed, so the drag is over.
  Lifted
}

/// How far a key press moves the panel.
pub type Size {
  /// One `fine_step`.
  Fine

  /// One `coarse_step`, for a press with Shift held.
  Coarse
}

/// What a key press on the grip asks for, or a double click.
pub type Adjustment {
  /// Widen the panel: the grip moves left, as the arrow does.
  Wider(size: Size)

  /// Narrow the panel: the grip moves right.
  Narrower(size: Size)

  /// Go to the widest width the room allows.
  Widest

  /// Go to `least_width`.
  Narrowest

  /// Go back to `default_width`.
  Reset
}

/// The widest the panel may be in `room`: what the two columns share, less the
/// floor the transcript keeps. It is never under `least_width`, so a window too
/// small for both floors keeps the panel usable and lets the stylesheet shrink
/// the transcript's column instead, and never over `most_width`, so a width the
/// reader chose on an enormous window is one storage will give back.
///
/// ## Examples
///
/// ```gleam
/// assert grip_rule.ceiling(grip_rule.Room(panel: 340, centre: 700)) == 680
/// assert grip_rule.ceiling(grip_rule.Room(panel: 340, centre: 100)) == 280
/// ```
pub fn ceiling(room: Room) -> Int {
  int.clamp(room.panel + room.centre - centre_floor, least_width, most_width)
}

/// `width` held between `least_width` and `ceiling`.
///
/// ## Examples
///
/// ```gleam
/// assert grip_rule.clamp(100, 600) == 280
/// assert grip_rule.clamp(900, 600) == 600
/// assert grip_rule.clamp(400, 600) == 400
/// ```
pub fn clamp(width: Int, ceiling: Int) -> Int {
  int.clamp(width, least_width, int.max(least_width, ceiling))
}

/// A drag that starts with the pointer at `origin` over a layout of `room`.
///
/// ## Examples
///
/// ```gleam
/// let drag = grip_rule.begin(900, grip_rule.Room(panel: 340, centre: 700))
/// assert drag == grip_rule.Drag(origin: 900, start: 340, ceiling: 680)
/// ```
pub fn begin(origin: Int, room: Room) -> Drag {
  Drag(origin:, start: room.panel, ceiling: ceiling(room))
}

/// The panel's width with the pointer at `pointer`. The panel is the right
/// column, so a pointer moving left of where it began widens the panel by the
/// same distance. The width comes from where the drag began and not from the
/// last width, so a pointer that went past a limit and returned finds the
/// panel exactly where it left off.
///
/// ## Examples
///
/// ```gleam
/// let drag = grip_rule.Drag(origin: 900, start: 340, ceiling: 680)
/// assert grip_rule.dragged(drag, 800) == 440
/// assert grip_rule.dragged(drag, 100) == 680
/// assert grip_rule.dragged(drag, 1500) == 280
/// ```
pub fn dragged(drag: Drag, pointer: Int) -> Int {
  clamp(drag.start + drag.origin - pointer, drag.ceiling)
}

/// Whether a pointer move belongs to a drag still under way, from the
/// `buttons` bit field the event carries. A browser does not report a release
/// that happened outside its window, so a move with no button down is what
/// tells the shell the drag is over.
///
/// ## Examples
///
/// ```gleam
/// assert grip_rule.contact(1) == grip_rule.Pressing
/// assert grip_rule.contact(0) == grip_rule.Lifted
/// ```
pub fn contact(buttons: Int) -> Contact {
  case buttons {
    0 -> Lifted
    _ -> Pressing
  }
}

/// What a key press on the grip asks for, or nothing for a key that is not the
/// grip's, which the browser keeps for itself (Tab moves on, for one). The
/// arrows move the panel the way the grip would move, Home goes to the
/// narrowest width and End to the widest, as the ARIA window-splitter pattern
/// has it.
///
/// ## Examples
///
/// ```gleam
/// assert grip_rule.adjustment("ArrowLeft", shell_rule.Free)
///   == Some(grip_rule.Wider(grip_rule.Fine))
/// assert grip_rule.adjustment("ArrowRight", shell_rule.Held)
///   == Some(grip_rule.Narrower(grip_rule.Coarse))
/// assert grip_rule.adjustment("Tab", shell_rule.Free) == None
/// ```
pub fn adjustment(key: String, shift: Modifier) -> Option(Adjustment) {
  let size = case shift {
    Held -> Coarse
    Free -> Fine
  }

  case key {
    "ArrowLeft" -> Some(Wider(size))
    "ArrowRight" -> Some(Narrower(size))
    "Home" -> Some(Narrowest)
    "End" -> Some(Widest)
    _ -> None
  }
}

/// The width after `adjustment`, from the width the panel has been asked to
/// be, kept within `room`. The starting width is the intended one and not the
/// one the browser has drawn so far: a held arrow key repeats faster than the
/// width finishes animating, and a step taken from the drawn width would
/// restart from wherever the transition had got to. A width the room no longer
/// holds, because the window shrank since, is brought inside it first, so the
/// first press moves from what the reader sees.
///
/// ## Examples
///
/// ```gleam
/// let room = grip_rule.Room(panel: 340, centre: 700)
/// assert grip_rule.adjusted(340, grip_rule.Wider(grip_rule.Fine), room) == 364
/// assert grip_rule.adjusted(340, grip_rule.Widest, room) == 680
/// assert grip_rule.adjusted(500, grip_rule.Reset, room) == 340
/// ```
pub fn adjusted(width: Int, adjustment: Adjustment, room: Room) -> Int {
  let ceiling = ceiling(room)
  let width = clamp(width, ceiling)

  case adjustment {
    Wider(size:) -> clamp(width + step(size), ceiling)
    Narrower(size:) -> clamp(width - step(size), ceiling)
    Widest -> ceiling
    Narrowest -> least_width
    Reset -> clamp(default_width, ceiling)
  }
}

// The distance a size of press moves the panel.
fn step(size: Size) -> Int {
  case size {
    Fine -> fine_step
    Coarse -> coarse_step
  }
}
