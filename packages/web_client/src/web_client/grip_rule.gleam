//// What `<loom-shell>` decides about the width of its two side columns, the
//// strand panel and the sessions sidebar: how far a drag moves each, what the
//// arrow keys do to it, and how large it may grow.
////
//// The panel is the frame's right column, 344 px wide until the reader
//// changes it. A Changes diff or a Trace row is wider than that, so the shell
//// draws a grip on the column's left edge, and the reader drags it left to
//// widen the panel or right to narrow it. The grip is also a keyboard control
//// (`adjustment`), because a pointer is not the only way to resize a window
//// and the ARIA window-splitter pattern asks for one.
////
//// The sessions sidebar is the left column and has a grip of its own on its
//// right edge. It is the panel's mirror image: the pointer moving right
//// widens it and so does the Right arrow. It has its own default and bounds
//// (`default_in`, `least_in`, `most_in`) because it holds a list of sessions
//// and not tabs. The panel's functions (`ceiling`, `clamp`, `begin`,
//// `dragged`, `adjustment`, `adjusted`) stay as the panel's; each has a
//// `_in` form that takes the `Region`, and the panel's form is that function
//// applied to `Panel`. Both regions share `centre_floor`, since the
//// transcript is one column between them and the room measured for either
//// grip already excludes the other column.
////
//// Three numbers bound a column's width. It never goes under its least
//// width, which keeps its content readable. It never takes the transcript
//// below `centre_floor`, which is the same floor the stylesheet gives the
//// centre column, so a drag cannot squeeze the conversation to nothing. And a
//// width read back from storage is never above its most width, so a stored
//// value that something else wrote cannot ask for a column wider than any
//// screen. The second bound depends on the window, so the shell measures how
//// much room there is when a gesture starts (`Room`) and this module turns
//// the measurement into a ceiling.
////
//// The module decides and does not act. It imports neither Lustre nor the DOM
//// binding, so the tests load it under Node, and it stores nothing: where the
//// width is kept is `web_client/layout_rule`'s concern.
////
//// ## Flow
////
//// `ceiling_in` → `begin_in` → `dragged_in`, and `adjustment_in` →
//// `adjusted_in`
////
//// 1. `ceiling_in` is the widest a column may be in the room that was
////    measured.
//// 2. `begin_in` records where a drag started, how wide the column was then
////    and the ceiling, so every later move is computed from the start and a
////    pointer that wanders past a limit and comes back has no dead zone.
//// 3. `dragged_in` is the width for the pointer's current position.
//// 4. `adjustment_in` decodes a key press on the grip, and `adjusted_in`
////    applies it.

import gleam/int
import gleam/option.{type Option, None, Some}
import web_client/shell_rule.{
  type Modifier, type Region, Free, Held, Panel, Sidebar,
}

/// The panel's width before the reader changes it, in pixels. The stylesheet's
/// fallback for the `--panel-width` property is the same number.
pub const default_width = 344

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

/// The sidebar's width before the reader changes it, in pixels. The
/// stylesheet's fallback for the `--sidebar-width` property is the same
/// number.
pub const sidebar_default_width = 232

/// The narrowest the sidebar may be, in pixels: room for a session's name and
/// its status.
pub const sidebar_least_width = 180

/// The widest the sidebar may be, in pixels. Unlike the panel's, this is a
/// layout limit and not only a sanity bound on stored text: past it the list
/// gains nothing and the transcript only loses room.
pub const sidebar_most_width = 480

/// How far an arrow key moves a column, in pixels.
pub const fine_step = 24

/// How far an arrow key moves a column while Shift is held, in pixels.
pub const coarse_step = 96

/// How wide the column being resized and the transcript were when a gesture
/// began, as the browser laid them out. The two together are the room the pair
/// shares, which is what a resize redistributes. The field is named for the
/// panel, which came first; for the sidebar's grip it holds the sidebar's
/// width.
pub type Room {
  Room(panel: Int, centre: Int)
}

/// A drag in progress. It holds the three facts the width is computed from.
pub type Drag {
  Drag(
    /// The pointer's horizontal position when the drag began.
    origin: Int,
    /// The column's width when the drag began.
    start: Int,
    /// The widest the column may be for this drag.
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

/// How far a key press moves a column.
pub type Size {
  /// One `fine_step`.
  Fine

  /// One `coarse_step`, for a press with Shift held.
  Coarse
}

/// What a key press on the grip asks for, or a double click.
pub type Adjustment {
  /// Widen the column: the panel's grip moves left, as the arrow does, and the
  /// sidebar's grip moves right.
  Wider(size: Size)

  /// Narrow the column: the panel's grip moves right, the sidebar's left.
  Narrower(size: Size)

  /// Go to the widest width the room allows.
  Widest

  /// Go to the region's least width.
  Narrowest

  /// Go back to the region's default width.
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
  ceiling_in(Panel, room)
}

/// `ceiling` for `region`: the same room arithmetic held to that region's own
/// bounds.
///
/// ## Examples
///
/// ```gleam
/// let wide = grip_rule.Room(panel: 232, centre: 700)
/// let tight = grip_rule.Room(panel: 232, centre: 100)
/// assert grip_rule.ceiling_in(shell_rule.Sidebar, wide) == 480
/// assert grip_rule.ceiling_in(shell_rule.Sidebar, tight) == 180
/// ```
pub fn ceiling_in(region: Region, room: Room) -> Int {
  int.clamp(
    room.panel + room.centre - centre_floor,
    least_in(region),
    most_in(region),
  )
}

/// The narrowest `region` may be, in pixels.
///
/// ## Examples
///
/// ```gleam
/// assert grip_rule.least_in(shell_rule.Sidebar) == 180
/// assert grip_rule.least_in(shell_rule.Panel) == 280
/// ```
pub fn least_in(region: Region) -> Int {
  case region {
    Sidebar -> sidebar_least_width
    Panel -> least_width
  }
}

/// The widest `region` may be on any window, in pixels.
///
/// ## Examples
///
/// ```gleam
/// assert grip_rule.most_in(shell_rule.Sidebar) == 480
/// assert grip_rule.most_in(shell_rule.Panel) == 4000
/// ```
pub fn most_in(region: Region) -> Int {
  case region {
    Sidebar -> sidebar_most_width
    Panel -> most_width
  }
}

/// The width `region` has before the reader changes it, in pixels.
///
/// ## Examples
///
/// ```gleam
/// assert grip_rule.default_in(shell_rule.Sidebar) == 232
/// assert grip_rule.default_in(shell_rule.Panel) == 344
/// ```
pub fn default_in(region: Region) -> Int {
  case region {
    Sidebar -> sidebar_default_width
    Panel -> default_width
  }
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
  clamp_in(Panel, width, ceiling)
}

/// `clamp` for `region`: `width` held between that region's least width and
/// `ceiling`.
///
/// ## Examples
///
/// ```gleam
/// assert grip_rule.clamp_in(shell_rule.Sidebar, 100, 400) == 180
/// assert grip_rule.clamp_in(shell_rule.Sidebar, 500, 400) == 400
/// ```
pub fn clamp_in(region: Region, width: Int, ceiling: Int) -> Int {
  let least = least_in(region)
  int.clamp(width, least, int.max(least, ceiling))
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
  begin_in(Panel, origin, room)
}

/// `begin` for `region`: the ceiling is that region's.
///
/// ## Examples
///
/// ```gleam
/// let room = grip_rule.Room(panel: 232, centre: 700)
/// let drag = grip_rule.begin_in(shell_rule.Sidebar, 232, room)
/// assert drag == grip_rule.Drag(origin: 232, start: 232, ceiling: 480)
/// ```
pub fn begin_in(region: Region, origin: Int, room: Room) -> Drag {
  Drag(origin:, start: room.panel, ceiling: ceiling_in(region, room))
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
  dragged_in(Panel, drag, pointer)
}

/// `dragged` for `region`. The sidebar is the left column, so a pointer
/// moving right of where it began widens it by the same distance: the mirror
/// of the panel.
///
/// ## Examples
///
/// ```gleam
/// let drag = grip_rule.Drag(origin: 232, start: 232, ceiling: 480)
/// assert grip_rule.dragged_in(shell_rule.Sidebar, drag, 328) == 328
/// assert grip_rule.dragged_in(shell_rule.Sidebar, drag, 900) == 480
/// assert grip_rule.dragged_in(shell_rule.Sidebar, drag, 0) == 180
/// ```
pub fn dragged_in(region: Region, drag: Drag, pointer: Int) -> Int {
  // The panel grows as the pointer moves left and the sidebar as it moves
  // right, so each region measures the pointer's travel from its own side.
  let travel = case region {
    Panel -> drag.origin - pointer
    Sidebar -> pointer - drag.origin
  }

  clamp_in(region, drag.start + travel, drag.ceiling)
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
  adjustment_in(Panel, key, shift)
}

/// `adjustment` for `region`. The arrows move the grip the way they point, so
/// the sidebar's Right arrow widens it and its Left arrow narrows it; Home and
/// End are the region's narrowest and widest.
///
/// ## Examples
///
/// ```gleam
/// assert grip_rule.adjustment_in(shell_rule.Sidebar, "ArrowRight", shell_rule.Free)
///   == Some(grip_rule.Wider(grip_rule.Fine))
/// assert grip_rule.adjustment_in(shell_rule.Sidebar, "ArrowLeft", shell_rule.Held)
///   == Some(grip_rule.Narrower(grip_rule.Coarse))
/// ```
pub fn adjustment_in(
  region: Region,
  key: String,
  shift: Modifier,
) -> Option(Adjustment) {
  // Choose coarse or fine adjustment based on shift modifier.
  let size = case shift {
    Held -> Coarse
    Free -> Fine
  }

  // Map the navigation key to an adjustment direction. The panel's grip is on
  // its left edge and the sidebar's on its right, so the arrow that widens
  // one narrows the other.
  case key, region {
    "ArrowLeft", Panel | "ArrowRight", Sidebar -> Some(Wider(size))
    "ArrowRight", Panel | "ArrowLeft", Sidebar -> Some(Narrower(size))
    "Home", _ -> Some(Narrowest)
    "End", _ -> Some(Widest)
    _, _ -> None
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
  adjusted_in(Panel, width, adjustment, room)
}

/// `adjusted` for `region`, with that region's bounds and default.
///
/// ## Examples
///
/// ```gleam
/// let room = grip_rule.Room(panel: 232, centre: 700)
/// let wider = grip_rule.Wider(grip_rule.Fine)
/// assert grip_rule.adjusted_in(shell_rule.Sidebar, 232, wider, room) == 256
/// assert grip_rule.adjusted_in(shell_rule.Sidebar, 400, grip_rule.Reset, room)
///   == 232
/// ```
pub fn adjusted_in(
  region: Region,
  width: Int,
  adjustment: Adjustment,
  room: Room,
) -> Int {
  let ceiling = ceiling_in(region, room)
  let width = clamp_in(region, width, ceiling)

  // Apply the requested adjustment step clamped to the room boundary.
  case adjustment {
    Wider(size:) -> clamp_in(region, width + step(size), ceiling)
    Narrower(size:) -> clamp_in(region, width - step(size), ceiling)
    Widest -> ceiling
    Narrowest -> least_in(region)
    Reset -> clamp_in(region, default_in(region), ceiling)
  }
}

// The distance a size of press moves a column.
fn step(size: Size) -> Int {
  case size {
    Fine -> fine_step
    Coarse -> coarse_step
  }
}
