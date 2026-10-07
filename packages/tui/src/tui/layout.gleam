//// Screen geometry: where each surface sits for a given model and screen.
////
//// Painting a frame and interpreting a mouse event have to agree on the
//// same rectangles, or a click lands on a row the operator cannot see. So
//// the rectangles are computed here, from the model and the screen size
//// alone, and both `tui/render` and `tui/interaction` call the same
//// functions. The projection and the tick use the transcript width and
//// height from here too, so a resize changes every reader at once.
////
//// The module also holds the few content measurements that decide a
//// height, such as the lines in the status band above the composer,
//// because the composer's height depends on them.
////
//// ## Flow
////
//// `layout` → `queue_body_layout` → `footer_split` → `hit_area`
////
//// 1. `layout` cuts the screen into the identity line, then the rail's column
////    (`rail_columns`, decided by `tui/rail`) from the right, and cuts what
////    is left into body, composer and footer rows, asking `input_height` and
////    `footer_height` (plus `strip_height`) how tall the last two must be. The
////    rail runs the height under the identity line, so the composer and the
////    footer span the transcript's column only, and every width they read is
////    `column_width`, not the terminal's.
//// 2. `queue_body_layout` takes the body and reserves the pinned todo panel and
////    the queue card (`body_split`, `queue_height`, `todo_height`), leaving the
////    conversation row.
//// 3. The conversation row is the transcript's whole. The rail is not part of
////    it: `rail_area` is the rail's rectangle and `rail_content_area` is what
////    its tab draws in, which is where the changes panel sits while the
////    changes are open (`diff_pane_width`).
//// 4. `footer_split` divides the footer rectangle into the footer proper and the
////    agent strip beneath it.
//// 5. The composer's own shape comes from `input_layout`, `input_view_state` and
////    `composer_status_lines`, because the status band decides its height.
//// 6. Readers ask for one rectangle instead of repeating the arithmetic:
////    `hit_area` for a click, `transcript_width` and `transcript_viewport_height`
////    for the projection and the tick, and the `*_area` functions for each overlay.

import core/todo_list
import etui/geometry.{type Rect, Fill, Length}
import etui/text
import etui/widgets/textarea as text_area
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/advisor_pending
import session_view/agent_roster
import session_view/agent_view
import session_view/commands
import session_view/composer
import session_view/context_view
import session_view/goal_view
import session_view/model.{Attached, Disconnected, Preview, Replaying} as session_model
import session_view/reviewer_status
import session_view/snapshot_view
import session_view/text_hygiene
import session_view/tool_activity
import session_view/transcript_line.{Stream}
import session_view/transcript_lines
import session_view/worktree_view
import tui/agent_strip
import tui/agents
import tui/diff_panel
import tui/input_frame
import tui/model.{
  type Model, AccessManager, AgentInspector, ApprovalInspector, DaemonSelector,
  DiffVisible, GoalInspector, ModelSelector, NoOverlay, PeerLinkManager,
} as tui_model
import tui/queue_editor
import tui/queue_panel
import tui/rail
import tui/todo_panel

/// The area inside a one-cell rounded border.
///
/// ## Examples
///
/// ```gleam
/// assert tui.panel_inner(geometry.rect_new(0, 1, 10, 5))
///   == geometry.rect_new(1, 2, 8, 3)
/// ```
@internal
pub fn panel_inner(area: Rect) -> Rect {
  geometry.rect_new(
    area.position.x + 1,
    area.position.y + 1,
    int.max(0, area.size.width - 2),
    int.max(0, area.size.height - 2),
  )
}

/// The transcript's reading area inside its panel: the full height but the
/// bottom row, which the reading row takes while the reader is above the
/// tail, and one cell in from each side for the gutter. The panel has no
/// heading row; the identity line names the strand.
///
/// ## Examples
///
/// ```gleam
/// assert layout.transcript_inner(geometry.rect_new(0, 1, 10, 5))
///   == geometry.rect_new(1, 1, 8, 4)
/// ```
@internal
pub fn transcript_inner(panel: Rect) -> Rect {
  geometry.rect_new(
    panel.position.x + 1,
    panel.position.y,
    int.max(0, panel.size.width - 2),
    int.max(0, panel.size.height - 1),
  )
}

/// Splits the screen into the header, body, composer and footer rows.
///
/// The footer rectangle includes the agent strip beneath the footer proper;
/// `footer_split` divides the two. Keeping them one rectangle here means
/// every hit-test and scroll path that reads the other three is unchanged
/// by the strip growing and shrinking.
@internal
pub fn layout(screen: Rect, model: Model) -> #(Rect, Rect, Rect, Rect) {
  let #(header, below) = case geometry.split_v(screen, [Length(1), Fill]) {
    [header, below] -> #(header, below)
    _ -> #(screen, screen)
  }
  let column = case
    geometry.split_h(below, [Fill, Length(rail_columns(model))])
  {
    [column, _] -> column
    _ -> below
  }
  case
    geometry.split_v(column, [
      Fill,
      Length(input_height(model)),
      Length(footer_height(model) + strip_height(model)),
    ])
  {
    [body, input, footer] -> #(header, body, input, footer)
    _ -> #(screen, screen, screen, screen)
  }
}

/// The tab the rail shows (`rail.tab`).
@internal
pub fn rail_tab(model: Model) -> rail.Tab {
  rail.tab(model.view.diff_view, model.view.rail_tab)
}

/// The columns the rail takes, its separator included, or zero when it is
/// not docked (`rail.columns`).
@internal
pub fn rail_columns(model: Model) -> Int {
  rail.columns(model.view.width, model.view.rail, rail_tab(model))
}

/// Whether the sheet is on screen: the rail's form on a terminal too narrow to
/// dock it. It replaces the transcript, leaving the input frame where it is,
/// and it is shown when it was opened or when the changes are open, since
/// the changes live on the rail's Changes tab and a narrow terminal has no
/// other place for it. A terminal wide enough to dock the rail never shows it.
///
/// ## Examples
///
/// ```gleam
/// // layout.sheet_shown(model) == False  (at 120 columns or wider)
/// ```
@internal
pub fn sheet_shown(model: Model) -> Bool {
  model.view.width < rail.narrowest
  && case model.view.sheet, model.view.diff_view {
    tui_model.SheetOpen, _ | tui_model.SheetClosed, DiffVisible -> True
    tui_model.SheetClosed, tui_model.DiffHidden -> False
  }
}

/// Whether the rail is on screen in either form, docked or as the sheet.
/// Everything that reads what the rail shows or who has its keyboard asks this;
/// the geometry of the columns asks `rail_columns`.
@internal
pub fn rail_present(model: Model) -> Bool {
  rail_columns(model) > 0 || sheet_shown(model)
}

/// How many columns of the rail's rectangle are its separator: one when it is
/// docked beside the transcript, none for the sheet, which has no neighbour.
@internal
pub fn rail_lead(model: Model) -> Int {
  case rail_columns(model) > 0 {
    True -> 1
    False -> 0
  }
}

/// The width of the transcript's column: the terminal less the rail. The
/// composer wraps to it and the footer is sized by it.
@internal
pub fn column_width(model: Model) -> Int {
  model.view.width - rail_columns(model)
}

/// The rail's rectangle. Docked, it is the columns on the right, from the row
/// under the identity line to the last row, and its first column is the
/// separator. As the sheet it is the conversation's rectangle, which it
/// replaces. Zero-sized when the rail is neither, and while an approval is
/// open: the approval block spans the screen above the input frame, so a rail
/// beside it would leave its lower rows stranded beside the frame. The rail
/// steps aside in painting only. Its columns stay reserved, so opening or
/// closing an approval never changes the transcript's width, which would
/// re-wrap every row and re-place every image.
///
/// ## Examples
///
/// ```gleam
/// // layout.rail_area(screen, model).size.width == layout.rail_columns(model)
/// ```
@internal
pub fn rail_area(screen: Rect, model: Model) -> Rect {
  case model.view.overlay {
    ApprovalInspector(_) -> geometry.rect_zero()
    NoOverlay
    | ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | PeerLinkManager(_)
    | AccessManager(_) -> shown_rail_area(screen, model)
  }
}

// Where the rail is when it is on screen at all: the conversation's rectangle
// for the sheet, the docked column otherwise.
fn shown_rail_area(screen: Rect, model: Model) -> Rect {
  case sheet_shown(model) {
    True -> {
      let #(_, body, _, _) = layout(screen, model)
      let #(conversation, _) = queue_body_layout(body, model)
      conversation
    }
    False -> docked_rail_area(screen, model)
  }
}

fn docked_rail_area(screen: Rect, model: Model) -> Rect {
  case geometry.split_v(screen, [Length(1), Fill]) {
    [_, below] ->
      case geometry.split_h(below, [Fill, Length(rail_columns(model))]) {
        [_, rail] -> rail
        _ -> geometry.rect_zero()
      }
    _ -> geometry.rect_zero()
  }
}

/// The rail's content: the rail less its separator, its tab bar and rule at
/// the top, and its key hint at the bottom. A tab draws in this rectangle.
@internal
pub fn rail_content_area(screen: Rect, model: Model) -> Rect {
  let area = rail_area(screen, model)
  let lead = rail_lead(model)
  case area.size.width > 0 {
    True ->
      geometry.rect_new(
        area.position.x + lead,
        area.position.y + 2,
        int.max(0, area.size.width - lead),
        int.max(0, area.size.height - 3),
      )
    False -> geometry.rect_zero()
  }
}

/// Queue geometry is reserved before the transcript is painted. A focused card
/// may use half the body, while every size retains a bordered conversation row;
/// passive observation spends only the rows needed for three bounded entries.
@internal
pub fn queue_body_layout(body: Rect, model: Model) -> #(Rect, Rect) {
  queue_body_layout_for(body, model, queue_rows(model))
}

// The body splits into the conversation, the pinned todo panel, and the
// queue card, in that order from the top. Every hit-test and scroll path
// asks for the conversation through here, so the todo rows are subtracted
// in one place and no path can disagree about where the transcript ends.
fn queue_body_layout_for(
  body: Rect,
  model: Model,
  rows: List(snapshot_view.PendingInput),
) -> #(Rect, Rect) {
  let #(conversation, _panel, queue) = body_split(body, model, rows)
  #(conversation, queue)
}

fn body_split(
  body: Rect,
  model: Model,
  rows: List(snapshot_view.PendingInput),
) -> #(Rect, Rect, Rect) {
  let queue = queue_height(body, model, rows)
  let panel = todo_height(body, model, queue)
  case geometry.split_v(body, [Fill, Length(panel), Length(queue)]) {
    [conversation, panel, queue] -> #(conversation, panel, queue)
    _ -> #(body, geometry.rect_zero(), geometry.rect_zero())
  }
}

fn queue_height(
  body: Rect,
  model: Model,
  rows: List(snapshot_view.PendingInput),
) -> Int {
  let wanted = case model.view.queue_editor.surface, rows {
    queue_editor.Closed, [] -> 0
    queue_editor.Closed, _ -> int.min(5, list.length(rows) + 2)
    queue_editor.Inspector, _ | queue_editor.Editor, _ ->
      int.min(14, int.max(3, body.size.height / 2))
  }
  int.min(wanted, int.max(0, body.size.height - 3))
}

/// The active strand's todo board, when it has one.
@internal
pub fn todo_board(model: Model) -> Option(todo_list.Board) {
  dict.get(model.shared.todo_boards, model.shared.active_strand)
  |> option.from_result
}

// The panel may take a third of the body and must leave the conversation
// at least four rows beside whatever the queue card took, so on a short
// terminal it shrinks, windowing its phase, before the transcript does.
fn todo_height(body: Rect, model: Model, queue: Int) -> Int {
  let budget =
    int.min(body.size.height / 3, body.size.height - queue - min_conversation)
  todo_panel.height(todo_board(model), budget)
}

const min_conversation = 4

/// The pinned todo panel's rectangle: between the conversation and the
/// queue card, full body width, zero rows when there is no board.
///
/// ## Examples
///
/// ```gleam
/// // layout.todo_area(body, model).size.height == 0
/// ```
@internal
pub fn todo_area(body: Rect, model: Model) -> Rect {
  let #(_, panel, _) = body_split(body, model, queue_rows(model))
  panel
}

// The width the changes panel has in the rail, or zero when the changes are
// not open in a rail that is on screen. In the sheet that is the whole width.
fn diff_pane_width(model: Model) -> Int {
  case rail_tab(model), rail_columns(model) {
    rail.Changes, columns if columns > 0 -> columns - 1
    rail.Changes, _ ->
      case sheet_shown(model) {
        True -> model.view.width
        False -> 0
      }
    rail.Strands, _ | rail.Trace, _ | rail.Session, _ -> 0
  }
}

/// The rectangle the changes panel is drawn in: the rail's content while the
/// changes are open in a docked rail, and nothing otherwise.
@internal
pub fn changes_panel_area(screen: Rect, model: Model) -> Rect {
  case diff_pane_width(model) > 0 {
    True -> {
      // The panel's geometry is `panel_inner` of its rectangle everywhere, so
      // the rectangle is the content grown by the cell a border would take.
      // No border is drawn in the rail: the tab is the title and the
      // separator is the edge. The panel's content is inset one cell on each
      // side, so its text keeps the margin the Trace and Session rows have
      // and does not touch the separator or the screen's edge.
      let content = rail_content_area(screen, model)
      geometry.rect_new(
        content.position.x,
        content.position.y - 1,
        content.size.width,
        content.size.height + 2,
      )
    }
    False -> geometry.rect_zero()
  }
}

/// Whether the rail is docked on the Strands tab, where it lists the agents
/// the strip would list.
@internal
pub fn rail_lists_strands(model: Model) -> Bool {
  rail_tab(model) == rail.Strands && rail_present(model)
}

/// Whether the agents are listed anywhere the keyboard can enter: the strip
/// under the input, or the rail on Strands.
@internal
pub fn strands_listed(model: Model) -> Bool {
  strip_height(model) > 0
  || { rail_lists_strands(model) && list.drop(strip_lines(model), 1) != [] }
}

/// Whether any row of agents is drawn: the strip under the input, or the rail
/// on Strands, even when it lists a single agent. The elapsed figures on those
/// rows move with the clock, so the clock is ticked while any is drawn;
/// `strands_listed` is the narrower question of whether a keyboard can enter
/// them.
@internal
pub fn agents_drawn(model: Model) -> Bool {
  strip_height(model) > 0 || rail_lists_strands(model)
}

/// Whether the agent under the cursor is running and so can be stopped. A
/// settled agent has nothing to stop, and the key that stops one is ignored
/// there.
@internal
pub fn cursor_stoppable(model: Model) -> Bool {
  case model.view.strip_focus {
    agent_strip.Composing -> False
    agent_strip.Browsing(id) ->
      case list.find(strip_lines(model), fn(line) { line.id == id }) {
        Ok(line) ->
          case line.status {
            agent_view.Working | agent_view.Waiting | agent_view.NeedsInput ->
              True
            agent_view.Idle
            | agent_view.Finished
            | agent_view.Failed
            | agent_view.Halted
            | agent_view.Unavailable -> False
          }
        Error(Nil) -> False
      }
  }
}

/// Reports whether captured edits are on screen, either as the main
/// surface or as the automatic side pane.
@internal
pub fn diff_shown(model: Model) -> Bool {
  model.view.diff_view == DiffVisible || diff_pane_width(model) > 0
}

/// Reports whether the changes cover the transcript, so that nothing of it is
/// on screen to scroll, select or catch up to: they are open in the sheet,
/// which replaces it. Opened in the docked rail they do not, since the
/// transcript is still beside them. There is no third place for them: where
/// the rail cannot dock, the sheet is the rail.
///
/// ## Examples
///
/// ```gleam
/// // layout.diff_covers_transcript(model) == False  (nothing open)
/// ```
@internal
pub fn diff_covers_transcript(model: Model) -> Bool {
  model.view.diff_view == DiffVisible && sheet_shown(model)
}

/// Divides the footer rectangle from `layout` into the footer proper and the
/// agent strip pinned beneath it.
@internal
pub fn footer_split(area: Rect, model: Model) -> #(Rect, Rect) {
  case geometry.split_v(area, [Fill, Length(strip_height(model))]) {
    [footer, strip] -> #(footer, strip)
    _ -> #(area, geometry.rect_zero())
  }
}

/// The rows the agents are listed in, from the same roster the workspace uses.
///
/// Under the input the strip lists only the agents worth watching. While the
/// rail is docked on Strands it lists every agent, in the workspace's
/// attention order, settled ones and the advisor included, so the one cursor
/// and its keys (`agent_strip.key`) walk exactly the rows the rail draws.
@internal
pub fn strip_lines(model: Model) -> List(agent_strip.Line) {
  case rail_lists_strands(model) {
    True ->
      agents.listed(displayed_agents(model), agents.AllAgents)
      |> list.map(agent_roster.describe(model.shared.roster, _))
    False ->
      agent_strip.lines(
        tui_model.strip(model),
        displayed_agents(model),
        model.shared.active_strand,
      )
  }
}

/// The rows the agent strip takes on this screen.
@internal
pub fn strip_height(model: Model) -> Int {
  use <- bool.guard(rail_lists_strands(model), 0)
  agent_strip.height_for_count(
    agent_roster.listed_count(
      displayed_agents(model),
      model.shared.active_strand,
    ),
    model.view.height,
  )
}

fn footer_height(model: Model) -> Int {
  case
    model.view.queue_editor.surface != queue_editor.Closed
    && model.view.height <= 12
  {
    True -> 1

    // The everyday status lives on the input frame's rules, so the footer
    // takes rows only for Ctrl+g's accounting detail.
    False ->
      case model.shared.details_expanded {
        True -> footer_rows(column_width(model))
        False -> 0
      }
  }
}

/// The most cells each footer section may take, including the space each
/// side of it. `footer_sections` compacts every section to these, so the
/// row count below can be decided from the width alone.
@internal
pub const footer_project_cells = 70

/// The widest the footer lets the model name grow, in terminal cells.
@internal
pub const footer_model_cells = 30

/// The widest the footer lets the usage section grow, in terminal cells.
@internal
pub const footer_usage_cells = 70

/// The widest the footer lets the status section grow, in terminal cells.
@internal
pub const footer_status_cells = 42

/// Every section plus one separating cell: the width at which the footer
/// fits on one row. A function because a Gleam constant cannot add.
@internal
pub fn footer_single_row_cells() -> Int {
  footer_project_cells
  + footer_model_cells
  + footer_usage_cells
  + footer_status_cells
  + 1
}

/// The rows the footer takes at a terminal width — one, two or three —
/// decided from the width and the sections' fixed caps, never from what
/// the sections happen to say.
///
/// That is the whole point of the caps. Measuring the rendered text
/// instead made the footer flip between one row and two as a turn ran:
/// `main: assistant` is wider than `main: done`, a `tok/s` suffix appears
/// once a generation settles, and each change pushed the total across
/// the threshold and moved the prompt box up or down under the operator's
/// hands. A layout that depends only on the window can only change when
/// the window does.
///
/// ## Examples
///
/// ```gleam
/// assert tui.footer_rows(213) == 1
/// assert tui.footer_rows(133) == 2
/// assert tui.footer_rows(40) == 3
/// ```
///
@internal
pub fn footer_rows(width: Int) -> Int {
  let single = footer_single_row_cells()
  let pair =
    int.max(
      footer_project_cells + footer_model_cells,
      footer_usage_cells + footer_status_cells,
    )
  case width >= single, width >= pair {
    True, _ -> 1
    False, True -> 2
    False, False -> 3
  }
}

/// Divides the prompt panel's interior between attachment chips and the editor.
///
/// The chip row is stacked above the editor rather than placed beside it. A
/// chip summary carries a filename, a mime type and a byte count, so a side by
/// side split gave the chip most of the panel and left the editor a column or
/// two — the operator could no longer read the sentence they were typing. A
/// full width editor with one row per image above it keeps every accepted
/// attachment visible, independently of filename length.
///
/// ## Examples
///
/// ```gleam
/// let #(chips, editor) = tui.input_layout(area, [])
/// assert chips == geometry.rect_zero()
/// assert editor == area
/// ```
///
@internal
pub fn input_layout(
  area: Rect,
  attachments: List(composer.Attachment),
) -> #(Rect, Rect) {
  case composer.preview_lines(attachments) {
    [] -> #(geometry.rect_zero(), area)

    // A panel one row tall has nothing to give the chip row. Yielding the
    // whole area to the editor keeps the prompt usable; the chip is dropped
    // for this frame rather than the text the operator is writing.
    rows ->
      case
        geometry.split_v(area, [
          Length(int.min(list.length(rows), int.max(0, area.size.height - 1))),
          Fill,
        ])
      {
        [chip_area, editor_area] -> #(chip_area, editor_area)
        [] | [_] | [_, _, _, ..] -> #(geometry.rect_zero(), area)
      }
  }
}

// The editor owns the unwrapped source text, while its view is wrapped to the
// current terminal width. Keeping this transformation render-only preserves
// the exact prompt bytes used by editing, history, and submission.
@internal
pub fn input_view_state(
  state: text_area.TextAreaState,
  available_width: Int,
) -> text_area.TextAreaState {
  let width = int.max(2, available_width)
  let text_area.TextAreaState(lines:, cursor_x:, cursor_y:) = state
  let current_line =
    lines |> list.drop(cursor_y) |> list.first |> result.unwrap("")
  let cursor_prefix = text.truncate(current_line, cursor_x, "")
  let #(cursor_row, wrapped_cursor_x) = wrapped_cursor(cursor_prefix, width, 0)
  let rows_before =
    lines
    |> list.take(cursor_y)
    |> list.flat_map(hard_wrap_line(_, width))
    |> list.length
  let wrapped_lines =
    lines
    |> list.index_map(fn(line, index) {
      let wrapped = hard_wrap_line(line, width)
      case index == cursor_y, list.drop(wrapped, cursor_row) {
        True, [] -> list.append(wrapped, [""])
        _, _ -> wrapped
      }
    })
    |> list.flatten
  text_area.TextAreaState(
    lines: wrapped_lines,
    cursor_x: wrapped_cursor_x,
    cursor_y: rows_before + cursor_row,
  )
}

fn hard_wrap_line(line: String, width: Int) -> List(String) {
  case line {
    "" -> [""]
    _ -> hard_wrap_nonempty(line, width, [])
  }
}

fn hard_wrap_nonempty(
  line: String,
  width: Int,
  rows: List(String),
) -> List(String) {
  case line {
    "" -> list.reverse(rows)
    _ -> {
      let chunk = text.truncate(line, width, "")
      let rest = string.drop_start(line, string.length(chunk))
      hard_wrap_nonempty(rest, width, [chunk, ..rows])
    }
  }
}

fn wrapped_cursor(prefix: String, width: Int, rows: Int) -> #(Int, Int) {
  let prefix_width = text.cell_width(prefix)
  case prefix_width < width {
    True -> #(rows, prefix_width)
    False -> {
      let chunk = text.truncate(prefix, width, "")
      let rest = string.drop_start(prefix, string.length(chunk))
      wrapped_cursor(rest, width, rows + 1)
    }
  }
}

fn input_height(model: Model) -> Int {
  // Reserve the same rows that `input_layout` assigns to the attachment
  // list, so every accepted image is visible above the editor.
  let chip_rows =
    model.shared.attachments |> composer.preview_lines |> list.length

  let content_rows =
    model.view.input
    |> input_view_state(editor_content_width(model))
    |> text_area.line_count
    |> int.max(1)
    |> int.min(4)

  content_rows + 2 + chip_rows + pending_height(model)
}

fn pending_height(model: Model) -> Int {
  list.length(composer_status_lines(model))
}

/// The status lines drawn in the band above the composer: the pending
/// submission, the first advisor nudge, the reviewer roster and the send state.
@internal
pub fn composer_status_lines(model: Model) -> List(String) {
  let pending = case pending_status(model) {
    None -> []
    Some(text) -> [text]
  }

  // The nudge panel sits under the reviewer roster and above the send state:
  // it is context for the prompt about to be written, not a report on one
  // already sent. An empty queue renders nothing, so the band keeps its
  // height when the advisor has nothing waiting.
  let queue_focused = model.view.queue_editor.surface != queue_editor.Closed
  let nudges = case model.shared.nudges, queue_focused {
    _, True | None, False -> []
    Some(board), False -> list.take(advisor_pending.lines(board), 1)
  }

  // A pinned goal keeps one row above the nudges for as long as it is
  // pinned. It is the standing objective the next prompt is written
  // against, so unlike the nudge queue it is not consumed by a run start
  // and does not disappear while the session works.
  let goal = case model.shared.goal, queue_focused {
    _, True | None, False -> []
    Some(board), False -> goal_view.row(board)
  }

  // The workspace, the visible rail and the agent strip already own the
  // roster. Repeating it above the editor would spend its typing space on
  // the same observation.
  let reviewers = case model.view.overlay, queue_focused {
    _, True | AgentInspector(_), False -> []
    _, False ->
      case rail_lists_strands(model) || strip_height(model) > 0 {
        True -> []
        False -> reviewer_band_lines(model)
      }
  }

  // What the strand is doing is on the input frame's top rule, unless the
  // frame is too narrow to carry it beside the keys.
  let active = case
    active_status_label(model),
    column_width(model) < input_frame.carries_activity
  {
    Some(status), True -> [
      activity_glyph(model.view.activity_frame)
      <> " "
      <> text_hygiene.single_line(status)
      <> elapsed_label(model.shared.activity_elapsed_s),
    ]
    Some(_), False | None, _ -> []
  }

  // A notice and the reason behind an unusual key are news, so they sit
  // here inside the frame rather than on its rules, which carry keys and
  // figures.
  // The queue editor owns the band while it is focused, as it does for the
  // nudges and the goal.
  // The reason behind a held key says what the interrupt's own notice says,
  // so while it stands the notice is not drawn a second time.
  let reason = input_keys(model).1 |> option.unwrap("")
  let notice = case model.shared.notice == commands.stopping_notice, reason {
    True, "" | False, _ -> text_hygiene.single_line(model.shared.notice)
    True, _ -> ""
  }
  let news = case queue_focused {
    True -> []
    False ->
      list.flatten([
        [model.view.cache_outlook],
        wrapped_notice(notice, column_width(model) - notice_margin),
        [reason],
      ])
      |> list.filter(fn(piece) { piece != "" })
  }
  list.flatten([active, reviewers, goal, nudges, news, pending])
}

// The cells the band does not offer a notice: the frame's two border cells and
// the one the band's rows start in from the side.
const notice_margin = 3

// The most rows a notice may take. A refusal can name a path and then the
// remedy, and the remedy is the part the operator needs, so a notice wraps
// instead of being cut at the edge; the cap keeps a pathological one from
// taking the transcript's rows.
const notice_rows = 3

// A notice as the rows it wraps to within `width` cells, the last one ending in
// an ellipsis when the cap cut the text short.
//
// Rows break at spaces, so a refusal never reads `att` / `empts`. A single
// word wider than the row cannot stay whole and is broken inside, which is
// the one case `text.wrap` does that. A notice is one line of prose with no
// cursor in it, unlike the composer's own wrap (`hard_wrap_line`), which must
// keep every character where the cursor can find it.
fn wrapped_notice(notice: String, width: Int) -> List(String) {
  let width = int.max(1, width)
  let rows = text.wrap(notice, width)

  case list.length(rows) > notice_rows {
    False -> rows
    True ->
      list.take(rows, notice_rows - 1)
      |> list.append([
        text.truncate(
          list.drop(rows, notice_rows - 1) |> string.join(" "),
          width,
          "…",
        ),
      ])
  }
}

// An ordinary-height narrow terminal has no agent rail, so the composer owns
// one reviewer's two-row status. Keep that small slot when the reviewer
// settles: otherwise the title and cursor jump down by two rows at exactly the
// moment the operator is likely to start typing a follow-up. The idle row is a
// current fact and the task slot is empty, so completion does not leave stale
// work looking live. Tiny terminals keep every row for the transcript and
// editor instead.
fn reviewer_band_lines(model: Model) -> List(String) {
  let idle_advisor =
    model.view.height >= 20
    && model.shared.active_strand != advisor_pending.advisor_strand
    && session_model.is_known_strand(
      model.shared.strands,
      advisor_pending.advisor_strand,
    )
    && !session_model.strand_running(
      model.shared,
      advisor_pending.advisor_strand,
    )
  case
    reviewer_status.lines(
      model.shared.reviewer_rows,
      model.shared.active_strand,
    ),
    idle_advisor
  {
    [], True -> ["Advisor · idle · /agents to inspect", ""]
    lines, _ -> lines
  }
}

/// What the next key does on the input frame's top rule, and the reason it
/// is not the ordinary Enter when there is one, for the status band.
///
/// Composer guidance answers what the next Enter does. The agent rail can
/// still display the last operation's outcome, so its terminal status alone
/// cannot establish whether this idle strand retains queued input.
///
/// ## Examples
///
/// ```gleam
/// // layout.input_keys(model) == #(" Enter sends ", None)
/// ```
@internal
pub fn input_keys(model: Model) -> #(String, Option(String)) {
  use <- bool.guard(
    model.shared.captured != None
      && !session_model.is_known_strand(
      model.shared.strands,
      model.shared.active_strand,
    ),
    #(" ^O agents ", Some("Recipient unavailable · your draft is kept")),
  )
  use <- bool.guard(
    model.shared.peer == session_model.Disconnected,
    case model.view.reconnect {
      tui_model.ReconnectAttempting(..) -> #(
        " draft kept ",
        Some("Reconnecting to the daemon · draft retained"),
      )
      tui_model.ReconnectIdle | tui_model.ReconnectSpent -> #(
        " /sessions reconnects ",
        Some("Disconnected · /sessions to reconnect · draft retained"),
      )
    },
  )
  let held = #(
    " Enter sends held input ",
    Some("Stopped · your next message is sent with the held input"),
  )
  use <- bool.guard(tui_model.active_queue_halted(model), held)
  case
    session_model.active_interrupt(model.shared),
    active_status_label(model),
    model.view.submission_mode
  {
    Some(_), _, _ -> held
    None, None, _ -> #(" Enter sends ", None)
    None, Some(_), tui_model.SteerNow -> #(" Enter steers · Tab queues ", None)
    None, Some(_), tui_model.PromptNext -> #(
      " Enter queues · Tab steers ",
      None,
    )
  }
}

/// Splits the composer panel into the status band above and the editor
/// below.
@internal
pub fn pending_layout(area: Rect, model: Model) -> #(Rect, Rect) {
  case geometry.split_v(area, [Length(pending_height(model)), Fill]) {
    [status, composer] -> #(status, composer)
    _ -> #(geometry.rect_zero(), area)
  }
}

// Receipt is a server fact; sending and waiting for a free channel are local
// facts. Naming them separately prevents an accepted queue from looking lost.
fn pending_status(model: Model) -> Option(String) {
  case model.shared.pending_submission, model.shared.awaiting_outcome {
    Some(_), _ -> Some("Not sent yet · waiting for session sync · Esc cancels")
    None, Some(_) -> Some("Sent · waiting for receipt")
    None, None -> None
  }
}

// Stacking the chips leaves the editor the full interior width, so the wrap
// the operator sees no longer depends on what is attached.
fn editor_content_width(model: Model) -> Int {
  int.max(2, column_width(model) - input_frame.prompt_margin)
}

/// How long the active strand has been busy, in the shape the prompt
/// border shows beside its phase: empty in the first second, then `(7s)`,
/// then `(1m 05s)` once a minute has passed.
///
/// ## Examples
///
/// ```gleam
/// assert tui.elapsed_label(0) == ""
/// assert tui.elapsed_label(7) == " (7s)"
/// assert tui.elapsed_label(65) == " (1m 05s)"
/// ```
///
@internal
pub fn elapsed_label(seconds: Int) -> String {
  case seconds <= 0, seconds >= 60 {
    True, _ -> ""
    False, False -> " (" <> int.to_string(seconds) <> "s)"
    False, True -> {
      let rest = seconds % 60
      let padded = case rest < 10 {
        True -> "0" <> int.to_string(rest)
        False -> int.to_string(rest)
      }
      " (" <> int.to_string(seconds / 60) <> "m " <> padded <> "s)"
    }
  }
}

/// Returns the low-motion activity indicator used by the prompt border.
@internal
pub fn activity_glyph(frame: Int) -> String {
  case int.modulo(frame / 3, 4) |> result.unwrap(0) {
    0 -> "◐"
    1 -> "◓"
    2 -> "◑"
    _ -> "◒"
  }
}

/// The operation phase is authoritative for liveness, while the latest stream
/// kind supplies the finer distinction the protocol phase cannot express. In
/// particular, `assistant` begins before the first reasoning delta, so treating
/// it as a completed response would make a steerable turn look stuck.
@internal
pub fn active_status_label(model: Model) -> Option(String) {
  case session_model.active_strand_phase(model.shared) {
    None -> None
    Some("assistant") ->
      Some(case active_stream_kind(model) {
        Some("text") -> "responding"
        Some("tool_call") -> "calling tool"
        _ -> "thinking"
      })
    Some("tools") -> Some(running_tool_label(model))
    Some("starting") -> Some("starting")
    Some("checkpoint") -> Some("checkpointing")
    Some("compacting") -> Some("compacting")
    Some("awaiting_deferred") -> Some("waiting")
    Some("failure_drain") -> Some("finishing failure")
    Some("cancel_requested") -> Some("stopping")
    Some(phase) -> Some(text_hygiene.single_line(phase))
  }
}

fn running_tool_label(model: Model) -> String {
  let calls = case model.shared.captured {
    None -> []
    Some(#(_, view)) ->
      case dict.get(view.operations, model.shared.active_strand) {
        Error(Nil) -> []
        Ok(current) ->
          tool_activity.running(
            view.cells,
            list.map(model.shared.records, fn(record) { record.entry }),
            current,
          )
      }
  }
  case calls {
    [] -> "preparing tools"
    [call, ..rest] ->
      transcript_lines.compact(
        transcript_lines.tool_call_summary(call.name, call.arguments, False),
        72,
      )
      <> case rest {
        [] -> ""
        more -> " + " <> int.to_string(list.length(more)) <> " running"
      }
  }
}

fn active_stream_kind(model: Model) -> Option(String) {
  transcript_lines.display_streams(session_model.presentation(model.shared))
  |> list.reverse
  |> list.find(fn(stream) {
    let Stream(strand:, ..) = stream
    strand == model.shared.active_strand && stream.kind != "end"
  })
  |> result.map(fn(stream) {
    let Stream(kind:, ..) = stream
    kind
  })
  |> result.map(Some)
  |> result.unwrap(None)
}

/// The width available to patch rows: the side pane when one is shown,
/// otherwise the transcript width.
@internal
pub fn diff_width(model: Model) -> Int {
  case diff_pane_width(model) {
    0 -> transcript_width(model)
    width -> int.max(1, width - 2)
  }
}

/// A compact goal inspector may cover the pending status bands, but never the
/// editable composer. Busy reviewers and the standing goal row can consume the
/// ordinary body completely at 40x12; the editor's real top is the stable lower
/// boundary both rendering and navigation use.
@internal
pub fn goal_inspector_area(body: Rect, editor: Rect) -> Rect {
  case body.size.height >= 6 {
    True -> body
    False ->
      geometry.rect_new(
        body.position.x,
        body.position.y,
        body.size.width,
        int.max(0, editor.position.y - body.position.y),
      )
  }
}

/// The goal inspector's area for the model's current screen size.
@internal
pub fn model_goal_inspector_area(model: Model) -> Rect {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body, input, _) = layout(screen, model)
  let #(_, composer) = pending_layout(panel_inner(input), model)
  let #(_, editor) = input_layout(composer, model.shared.attachments)
  goal_inspector_area(body, editor)
}

/// The area the notes panel is drawn into when it replaces the transcript.
@internal
pub fn note_detail_area(model: Model) -> Rect {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body, _, _) = layout(screen, model)
  let #(conversation, _) = queue_body_layout(body, model)
  let transcript = conversation
  transcript_inner(transcript)
}

/// Returns the message preview's actual rectangle for viewport regressions.
///
/// ## Examples
///
/// ```gleam
/// // tui.message_detail_area(model)
/// ```
@internal
pub fn message_detail_area(model: Model) -> Rect {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body, _, _) = layout(screen, model)
  let inspector = case model.view.overlay {
    AgentInspector(inspector) -> inspector
    _ -> agents.inspect(model.shared.active_strand)
  }
  agents.inspection_detail_area(
    workspace_area(screen, body, inspector),
    displayed_agents(model),
    inspector,
  )
}

/// Where the agent workspace is drawn. While the operator browses it owns
/// the screen below the identity line, covering the strip and the input
/// frame; while they write to the recipient from inside it, the composer
/// keeps its rows and the workspace takes the body above it.
///
/// ## Examples
///
/// ```gleam
/// // layout.workspace_area(screen, body, agents.inspect("main"))
/// ```
@internal
pub fn workspace_area(
  screen: Rect,
  body: Rect,
  inspector: agents.Inspector,
) -> Rect {
  case inspector.focus {
    agents.Composing -> body
    agents.Browsing ->
      geometry.rect_new(
        screen.position.x,
        screen.position.y + 1,
        screen.size.width,
        int.max(0, screen.size.height - 1),
      )
  }
}

/// The area a press at this cell selects within.
///
/// The panels are tried innermost first, so a press on the transcript's text
/// selects transcript rows without the border glyphs; a press anywhere else,
/// a border or the header or footer, selects across the whole screen the way
/// a terminal would.
///
/// ## Examples
///
/// ```gleam
/// assert tui.hit_area(model, geometry.Position(2, 2))
///   == tui.panel_inner(transcript_panel)
/// ```
@internal
pub fn hit_area(model: Model, at: geometry.Position) -> Rect {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body_area, input_area, _) = layout(screen, model)
  let #(conversation, queue) = queue_body_layout(body_area, model)

  // The sheet covers the transcript, so a point on it is not on the
  // transcript whatever tab the sheet shows.
  let transcript = case sheet_shown(model) {
    True -> geometry.rect_zero()
    False -> transcript_inner(conversation)
  }
  [
    transcript,
    panel_inner(changes_panel_area(screen, model)),
    panel_inner(input_area),
    panel_inner(queue),
  ]
  |> list.find(fn(area) { geometry.contains(area, at) })
  |> result.unwrap(screen)
}

/// The number of transcript rows visible at the current screen size.
@internal
pub fn transcript_viewport_height(model: Model) -> Int {
  let screen = model_screen(model)
  let #(_, body, _, _) = layout(screen, model)
  let #(conversation, _) = queue_body_layout(body, model)
  int.max(1, transcript_inner(conversation).size.height)
}

/// Returns the transcript rows left after fixed terminal surfaces are reserved.
@internal
pub fn transcript_height(
  height: Int,
  input_rows: Int,
  footer_rows: Int,
) -> Int {
  // The identity line consumes one row and the reading row one more.
  int.max(1, height - input_rows - footer_rows - 2)
}

/// The width of a transcript row at the current screen size.
@internal
pub fn transcript_width(model: Model) -> Int {
  let screen = model_screen(model)
  let #(_, body, _, _) = layout(screen, model)
  let #(conversation, _) = queue_body_layout(body, model)
  let main = conversation
  int.max(1, main.size.width - 2)
}

/// The active strand's pending inputs in the captured cut.
@internal
pub fn queue_rows(model: Model) -> List(snapshot_view.PendingInput) {
  session_model.queue_rows(model.shared)
}

/// The control hint shown in the smallest queue panel.
@internal
pub fn tiny_queue_controls() -> String {
  "Pg ↵ e Esc"
}

/// The badge suffix for a queue row and the width left for the row's text.
@internal
pub fn tiny_queue_measure(
  row: snapshot_view.PendingInput,
  controls: String,
  width: Int,
) -> #(String, Int) {
  let badges = case row.kind, row.editing {
    snapshot_view.Queue, snapshot_view.Editable -> "Q EDIT"
    snapshot_view.Queue, snapshot_view.ReadOnly -> "Q READ-ONLY"
    snapshot_view.Steer, snapshot_view.Editable -> "STEER EDIT"
    snapshot_view.Steer, snapshot_view.ReadOnly -> "STEER READ-ONLY"
  }
  let suffix = " · " <> badges <> " · " <> controls
  #(suffix, int.max(1, width - text.cell_width(suffix) - 3))
}

/// The whole screen as a rectangle, at the size the model last saw.
@internal
pub fn model_screen(model: Model) -> geometry.Rect {
  geometry.rect_new(0, 0, model.view.width, model.view.height)
}

fn model_queue_area_for(
  model: Model,
  rows: List(snapshot_view.PendingInput),
) -> geometry.Rect {
  let #(_, body, _, _) = layout(model_screen(model), model)
  queue_body_layout_for(body, model, rows).1
}

/// The area the selected queue row is previewed in.
@internal
pub fn queue_preview_area(model: Model) -> geometry.Rect {
  queue_preview_area_for(model, queue_rows(model))
}

/// The area the selected row of `rows` is previewed in, which shrinks to a
/// single row in the smallest queue panels.
@internal
pub fn queue_preview_area_for(
  model: Model,
  rows: List(snapshot_view.PendingInput),
) -> geometry.Rect {
  let area = model_queue_area_for(model, rows)
  let content = queue_content_area(area)
  case area.size.height {
    height if height <= 2 ->
      case list.first(list.drop(rows, model.view.queue_editor.selected)) {
        Error(Nil) -> content
        Ok(row) -> {
          let #(_, width) =
            tiny_queue_measure(row, tiny_queue_controls(), area.size.width)
          geometry.rect_new(area.position.x, area.position.y, width, 3)
        }
      }
    height if height <= 4 ->
      case list.first(list.drop(rows, model.view.queue_editor.selected)) {
        Error(Nil) -> content
        Ok(row) -> {
          let width = queue_panel.tiny_preview_width(row, content.size.width)
          geometry.rect_new(content.position.x, content.position.y, width, 3)
        }
      }
    _ -> content
  }
}

/// The part of a queue panel below its control rows.
@internal
pub fn queue_content_area(area: geometry.Rect) -> geometry.Rect {
  let inner = panel_inner(area)
  let controls = queue_control_rows(area)
  geometry.rect_new(
    inner.position.x,
    inner.position.y + controls,
    inner.size.width,
    int.max(0, inner.size.height - controls),
  )
}

/// The number of control rows a queue panel of this size shows.
@internal
pub fn queue_control_rows(area: Rect) -> Int {
  int.min(3, int.max(0, panel_inner(area).size.height - 1))
}

/// The area the queue draft editor is drawn into.
@internal
pub fn queue_draft_area(area: Rect) -> Rect {
  let inner = panel_inner(area)
  let controls = queue_control_rows(area)
  geometry.rect_new(
    inner.position.x,
    inner.position.y + controls,
    inner.size.width,
    int.max(0, inner.size.height - controls),
  )
}

/// The part of the summary surface below its tab row.
@internal
pub fn summary_body_area(screen: Rect) -> Rect {
  let inner = panel_inner(screen)
  let tabs = int.min(2, inner.size.height)
  geometry.rect_new(
    inner.position.x,
    inner.position.y + tabs,
    inner.size.width,
    int.max(0, inner.size.height - tabs),
  )
}

fn normal_diff_panel(model: Model) -> Rect {
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body, _, _) = layout(screen, model)
  let #(conversation, _) = queue_body_layout(body, model)
  let main = conversation
  case diff_pane_width(model) {
    0 -> main
    _ -> changes_panel_area(screen, model)
  }
}

/// A taller changes panel that borrows the rows above the composer, when
/// the side pane is too short to navigate and nothing else owns focus.
@internal
pub fn borrowed_diff_panel(model: Model) -> Option(Rect) {
  let normal = normal_diff_panel(model)

  // A panel in the docked rail has the rail's whole height, and drawing a
  // taller one over it would cover the tab bar. The sheet is short on a short
  // terminal, and may borrow.
  use <- bool.guard(
    !diff_borrow_eligible(model)
      || panel_inner(normal).size.height >= 8
      || { diff_pane_width(model) > 0 && rail_columns(model) > 0 },
    None,
  )
  let screen = geometry.rect_new(0, 0, model.view.width, model.view.height)
  let #(_, body, input, _) = layout(screen, model)
  let #(_, composer) = pending_layout(panel_inner(input), model)
  let #(_, editor) = input_layout(composer, model.shared.attachments)
  let expanded =
    geometry.rect_new(
      normal.position.x,
      body.position.y,
      normal.size.width,
      int.max(0, editor.position.y - body.position.y),
    )
  case expanded.size.height > normal.size.height {
    True -> Some(expanded)
    False -> None
  }
}

/// Reports whether the changes panel may borrow rows above the composer.
@internal
pub fn diff_borrow_eligible(model: Model) -> Bool {
  diff_shown(model)
  && model.shared.worktree.focus == worktree_view.Navigator
  && case model.view.overlay {
    NoOverlay -> True
    ModelSelector(_)
    | AgentInspector(_)
    | GoalInspector(_)
    | DaemonSelector(_)
    | PeerLinkManager(_)
    | AccessManager(_)
    | ApprovalInspector(_) -> False
  }
  && !model.view.notes_open
  && model.view.queue_editor.surface == queue_editor.Closed
  && model.view.summary_surface == queue_editor.Closed
  && model.shared.context.surface == context_view.Hidden
}

/// The changes panel in use: the borrowed one when it applies, otherwise
/// the normal one.
@internal
pub fn active_diff_panel(model: Model) -> Rect {
  case borrowed_diff_panel(model) {
    Some(area) -> area
    None -> normal_diff_panel(model)
  }
}

fn active_diff_layout(model: Model) -> diff_panel.Layout {
  let area = panel_inner(active_diff_panel(model))
  diff_panel.layout(
    area,
    list.length(worktree_view.labels(model.shared.worktree)),
    model.shared.worktree.selected,
  )
}

/// Returns the exact file-list rectangle used by rendering and mouse hits.
///
/// ## Examples
///
/// ```gleam
/// // tui.diff_navigation_area(model)
/// ```
@internal
pub fn diff_navigation_area(model: Model) -> Rect {
  active_diff_layout(model).navigation
}

/// Returns the existing patch renderer's actual focused viewport.
///
/// ## Examples
///
/// ```gleam
/// // tui.diff_patch_area(model)
/// ```
@internal
pub fn diff_patch_area(model: Model) -> Rect {
  active_diff_layout(model).patch
}

/// The number of patch rows the changes panel shows.
@internal
pub fn diff_patch_height(model: Model) -> Int {
  diff_patch_area(model).size.height
}

/// The index of the changed file under `at` in the changes navigator, if
/// the navigator is visible and has focus.
@internal
pub fn diff_navigation_hit(model: Model, at: geometry.Position) -> Option(Int) {
  use <- bool.guard(
    !diff_shown(model)
      || model.view.queue_editor.surface != queue_editor.Closed
      || model.view.summary_surface != queue_editor.Closed
      || model.shared.context.surface != context_view.Hidden,
    None,
  )
  use <- bool.guard(
    model.view.notes_open
      || case model.view.overlay {
      NoOverlay -> False
      _ -> True
    },
    None,
  )
  case
    diff_panel.navigation_hit(
      active_diff_layout(model),
      at,
      list.length(worktree_view.labels(model.shared.worktree)),
    )
  {
    Ok(index) -> Some(index)
    Error(Nil) -> None
  }
}

/// Legacy fixtures have no captured register cut. Their rows explicitly expose
/// unavailable task and result evidence instead of inventing successful work.
@internal
pub fn displayed_agents(model: Model) -> List(agent_view.Row) {
  let rows = case model.shared.captured {
    Some(_) -> model.shared.agent_rows
    None -> agent_view.legacy(model.shared.strands)
  }
  case model.shared.peer {
    Disconnected ->
      list.map(rows, fn(row) {
        agent_view.Row(
          ..row,
          status: agent_view.Unavailable,
          activity: "Disconnected · last observation may be stale",
          approvals: [],
        )
      })
    Attached | Preview | Replaying -> rows
  }
}
