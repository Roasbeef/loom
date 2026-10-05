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
////   dock at all; there `tui/rail_view` draws the same tabs as a sheet
////   over the transcript (`layout.sheet_shown`), which this module does not
////   decide: a sheet is not a preference and nothing here remembers it.
//// - **A remembered choice wins; with none, a wide terminal docks it.** At
////   160 columns and wider an operator who never touched the rail sees it
////   docked on Strands. Narrower, the operator opens it with Shift+Tab. The
////   choice is the one `layout_memory` keeps per workspace.
//// - **Opening the changes forces it.** `/diff` opens the rail on its
////   Changes tab wherever it fits, whatever was chosen, and closing the
////   changes puts the rail back as it was chosen.
//// - **The tab is a preference, except Changes.** A person leaves the rail on
////   Strands, Trace or Session and finds it there next time. Changes is the
////   changes setting's: it is open or it is not, and what the rail shows
////   when they close it is the tab they had.

import gleam/option.{type Option, None, Some}
import tui/layout_memory
import tui/model.{type DiffVisibility, DiffHidden, DiffVisible}

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

/// What the rail is showing. The four tabs and their order are the web
/// view's: Strands, Changes, Trace, Session.
pub type Tab {
  /// The agents, drawn by the row renderer the strip and the workspace use.
  Strands

  /// The session's own edits: the changes panel, hosted in the rail.
  Changes

  /// The strand's latest code-mode program, its result and its calls.
  Trace

  /// The session's goal, jobs, viewers and cost.
  Session
}

/// The tab the rail shows. While the changes are open it is Changes, which is
/// the changes setting's and not a choice of tab; otherwise it is the tab the
/// person left it on, Strands when they never chose one.
///
/// ## Examples
///
/// ```gleam
/// assert rail.tab(model.DiffHidden, option.None) == rail.Strands
/// assert rail.tab(model.DiffVisible, option.None) == rail.Changes
/// ```
pub fn tab(diff: DiffVisibility, chosen: Option(layout_memory.Tab)) -> Tab {
  case diff, chosen {
    DiffVisible, _ -> Changes
    DiffHidden, Some(layout_memory.TabTrace) -> Trace
    DiffHidden, Some(layout_memory.TabSession) -> Session
    DiffHidden, Some(layout_memory.TabStrands) | DiffHidden, None -> Strands
  }
}

/// The tab's number, which is the key that selects it.
///
/// ## Examples
///
/// ```gleam
/// assert rail.number(rail.Trace) == 3
/// ```
pub fn number(tab: Tab) -> Int {
  case tab {
    Strands -> 1
    Changes -> 2
    Trace -> 3
    Session -> 4
  }
}

/// The tab a number selects, or nothing for a number that selects none.
///
/// ## Examples
///
/// ```gleam
/// assert rail.of_number(4) == Ok(rail.Session)
/// assert rail.of_number(5) == Error(Nil)
/// ```
pub fn of_number(number: Int) -> Result(Tab, Nil) {
  case number {
    1 -> Ok(Strands)
    2 -> Ok(Changes)
    3 -> Ok(Trace)
    4 -> Ok(Session)
    _ -> Error(Nil)
  }
}

/// The tab's name as the tab bar draws it.
///
/// ## Examples
///
/// ```gleam
/// assert rail.name(rail.Changes) == "Changes"
/// ```
pub fn name(tab: Tab) -> String {
  case tab {
    Strands -> "Strands"
    Changes -> "Changes"
    Trace -> "Trace"
    Session -> "Session"
  }
}

/// The tab as the layout memory keeps it, or nothing for Changes, which is
/// never remembered.
///
/// ## Examples
///
/// ```gleam
/// assert rail.remembered(rail.Changes) == option.None
/// ```
pub fn remembered(tab: Tab) -> Option(layout_memory.Tab) {
  case tab {
    Strands -> Some(layout_memory.TabStrands)
    Trace -> Some(layout_memory.TabTrace)
    Session -> Some(layout_memory.TabSession)
    Changes -> None
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
    Strands, chosen, True | Trace, chosen, True | Session, chosen, True ->
      case chosen {
        Some(layout_memory.RailShown) -> cells(terminal) + 1
        Some(layout_memory.RailHidden) -> 0
        None ->
          case terminal >= docks_by_default {
            True -> cells(terminal) + 1
            False -> 0
          }
      }
  }
}
