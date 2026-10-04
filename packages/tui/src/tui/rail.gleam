//// Where the rail docks, and how wide it is.
////
//// The rail is the one column beside the transcript. It replaced two: the
//// 34-cell agent rail and the 72-cell changes pane, which both borrowed the
//// same place. It is a column of the terminal, not of the transcript: it runs
//// from the row under the identity line to the last row, and the input frame
//// spans the transcript's column only (`layout.layout`).
////
//// This module is the decision and nothing else, over plain values, so the
//// geometry in `tui/layout` and the painting in `tui/rail_view` ask one
//// question and cannot disagree. Three rules fix it.
////
//// - **It docks only when the transcript keeps 75 cells.** At 44 cells wide
////   that is 120 columns (75 + 1 + 44), and the rail is 56 wide from 160
////   columns, where the transcript still keeps 103. Below 120 it does not
////   dock at all; a sheet for narrow terminals is a later slice.
//// - **A remembered choice wins; with none, a wide terminal docks it.** At
////   160 columns and wider an operator who never touched the rail sees it
////   docked on Strands. Narrower, the operator opens it with Shift+Tab. The
////   choice is the one `layout_memory` keeps per workspace.
//// - **Opening the changes forces it.** `/diff` opens the rail on its
////   Changes tab wherever it fits, whatever was chosen, and closing the
////   changes puts the rail back as it was chosen.

import gleam/option.{type Option, None, Some}
import tui/layout_memory
import tui/model.{type DiffVisibility, DiffAutomatic, DiffHidden, DiffVisible}

/// The narrowest terminal the rail docks in, in columns. The transcript keeps
/// 75 of them beside a 44-cell rail and its separator.
pub const narrowest = 120

/// The width from which the rail is docked without anyone asking.
pub const docks_by_default = 160

/// The cells of the rail's content on a terminal this wide: 56 from 160
/// columns, 44 below.
///
/// ## Examples
///
/// ```gleam
/// assert rail.cells(200) == 56
/// assert rail.cells(120) == 44
/// ```
pub fn cells(terminal: Int) -> Int {
  case terminal >= docks_by_default {
    True -> 56
    False -> 44
  }
}

/// What the rail is showing.
pub type Tab {
  /// The agents, drawn by the row renderer the strip and the workspace use.
  Strands

  /// The session's own edits: the changes panel, hosted in the rail.
  Changes
}

/// The tab the changes setting selects. While the changes are open the rail
/// is on Changes; otherwise it is on Strands.
///
/// ## Examples
///
/// ```gleam
/// assert rail.tab(model.DiffHidden) == rail.Strands
/// ```
pub fn tab(diff: DiffVisibility) -> Tab {
  case diff {
    DiffVisible -> Changes
    DiffAutomatic | DiffHidden -> Strands
  }
}

/// The columns the rail takes from a terminal `terminal` wide, its separator
/// included, or zero when it is not docked.
///
/// ## Examples
///
/// ```gleam
/// assert rail.columns(200, option.None, rail.Strands) == 57
/// assert rail.columns(100, option.Some(layout_memory.RailShown), rail.Strands) == 0
/// ```
pub fn columns(
  terminal: Int,
  choice: Option(layout_memory.Rail),
  tab: Tab,
) -> Int {
  let room = terminal >= narrowest
  case tab, choice, room {
    _, _, False -> 0
    Changes, _, True -> cells(terminal) + 1
    Strands, Some(layout_memory.RailShown), True -> cells(terminal) + 1
    Strands, Some(layout_memory.RailHidden), True -> 0
    Strands, None, True ->
      case terminal >= docks_by_default {
        True -> cells(terminal) + 1
        False -> 0
      }
  }
}
