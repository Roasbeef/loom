//// The agent workspace separates inspection from the message recipient.
////
//// The rail and workspace share bounded, evidence-based rows. Navigation holds
//// a stable strand identity, while only the explicit Open action can change
//// the transcript and composer.
////
//// The workspace is a list and a detail. The list draws one row per agent in
//// `agent_row`'s shape, the one the strip under the input uses too, in
//// attention order after `main`: what needs the operator, then what failed,
//// then what is working, then what has finished. Tab narrows it with a
//// `Filter`. The detail is a column of labelled sections for the selected
//// agent, each saying one thing once: its task, what it is doing now, its
//// latest messages, its inbox, its tools and, dimmest, its identity. A wide
//// workspace puts the detail beside the list; a narrow one stacks it under a
//// rule. The order and the filter are applied in one place, `listed`, which
//// navigation reads too, so Up and Down always move to the row drawn next.
////
//// While the operator browses, the workspace owns the screen below the
//// identity line: the strip and the input frame are covered, and the frame
//// is as tall as its content, anchored at the top as the session picker
//// is. Writing to the recipient from inside it (`w`) hands the composer
//// back its rows, so the workspace then sits in the body above it.
////
//// The latest messages are drawn oldest first, newest last, in the order
//// the transcript holds them. They carry no age: a captured send
//// (`agent_messages.Item`) holds its sequence, not a time, and an age
//// computed from anything else would be a guess.
////
//// ## Flow
////
//// `inspect` → `listed` → `render_inspection` → `render_full_inspection`
//// → `list_lines` → `render_detail` → `footer_lines`
////
//// 1. `inspect` starts an `Inspector` on the active strand, and `listed` is
////    the one place that orders and filters the rows for both drawing and
////    navigation.
//// 2. `navigate`, `next_attention` and `cycle_filter` move the selection or
////    the filter over that same list; none of them touches the transcript.
//// 3. `render_inspection` is the entry the shell calls. A screen under ten
////    rows gets `render_compact_inspection`; anything taller gets
////    `render_full_inspection`.
//// 4. `render_full_inspection` sizes the frame once with `geometry_for`, so
////    the list, divider, detail and footer agree on their rectangles.
//// 5. `list_lines` draws one shared-renderer row per agent, and `render_detail`
////    draws the selected agent's sections with `detail_rows`.
//// 6. `footer_lines` ends the frame with the keys the focus allows.

import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import session_view/agent_messages
import session_view/agent_roster
import session_view/agent_view.{type Row}
import session_view/protocol.{type Strand}
import session_view/text_hygiene
import tui/agent_row
import tui/theme

/// Inspection never owns the composer's recipient or draft.
@internal
pub type Inspector {
  Inspector(
    /// Stable strand identity, retained even if the strand disappears.
    selected: String,
    /// Independent scroll position within the selected detail.
    scroll: Int,
    /// Keyboard owner; inspection never consumes composer text.
    focus: Focus,
    /// The selected read-only detail, independent of the composer.
    detail: Detail,
    /// Durable invocation identity for the selected observed send.
    message: Option(String),
    /// Which agents the list shows.
    filter: Filter,
  )
}

/// The workspace keeps navigation and ordinary text entry unambiguous.
@internal
pub type Focus {
  /// Arrows inspect; Enter opens the selected transcript.
  Browsing

  /// Keys edit and submit the unchanged active recipient's draft.
  Composing
}

/// Every detail belongs to the inspected identity, never the message target.
@internal
pub type Detail {
  /// Current task, outcome, activity, and exact pending decisions.
  Overview

  /// Captured sends to and from the inspected strand.
  Messages

  /// Explicitly read durable notes for the inspected strand.
  Notes

  /// Captured async custody, peer links, workflows, and peer-authored input.
  Collaboration
}

/// Which agents the list shows, cycled with Tab as the session picker's
/// tabs are.
@internal
pub type Filter {
  /// Every agent.
  AllAgents

  /// Agents waiting on the operator, failed, or halted with input.
  AttentionAgents

  /// Agents with work in progress, including a provider wait.
  WorkingAgents

  /// Agents with nothing running: finished, idle or unavailable.
  SettledAgents
}

/// Direction is explicit at navigation call sites.
@internal
pub type Direction {
  /// Previous row, wrapping at the beginning.
  Previous

  /// Next row, wrapping at the end.
  Next
}

/// What the workspace draws beside each row's own projection: the figures
/// the strip already keeps, and the captured sends.
@internal
pub type Facts {
  Facts(
    /// The strip's roster, for each agent's elapsed time and context.
    roster: agent_roster.Roster,
    /// Captured inter-agent sends, newest first.
    messages: List(agent_messages.Item),
  )
}

/// Facts with nothing observed, for a workspace drawn without a session.
///
/// ## Examples
///
/// ```gleam
/// assert agents.no_facts().messages == []
/// ```
@internal
pub fn no_facts() -> Facts {
  Facts(roster: agent_roster.new(), messages: [])
}

/// Opens inspection on the current transcript without changing its draft.
///
/// ## Examples
///
/// ```gleam
/// assert agents.inspect("main").selected == "main"
/// ```
@internal
pub fn inspect(active: String) -> Inspector {
  Inspector(active, 0, Browsing, Overview, None, AllAgents)
}

/// The rows the list draws, in the order it draws them: the filter's rows,
/// `main` first, then by what most needs the operator, and otherwise in
/// roster order, so a row arriving never reorders the rows of its rank.
///
/// ## Examples
///
/// ```gleam
/// assert agents.listed([], agents.AllAgents) == []
/// ```
@internal
pub fn listed(rows: List(Row), filter: Filter) -> List(Row) {
  rows
  |> list.filter(fn(row) { admits(filter, row) })
  |> list.index_map(fn(row, index) { #(rank(row), index, row) })
  |> list.sort(fn(left, right) {
    int.compare(left.0, right.0)
    |> order.lazy_break_tie(fn() { int.compare(left.1, right.1) })
  })
  |> list.map(fn(entry) { entry.2 })
}

// Attention order: the primary leads, then the states that ask something
// of the operator, then work in flight, then what has settled. The advisor
// reviews rather than works, so it closes the list.
fn rank(row: Row) -> Int {
  case row.id, row.status {
    "main", _ -> 0
    "advisor", _ -> 9
    _, agent_view.NeedsInput -> 1
    _, agent_view.Failed -> 2
    _, agent_view.Halted -> 3
    _, agent_view.Working | _, agent_view.Waiting -> 4
    _, agent_view.Idle -> 5
    _, agent_view.Finished -> 6
    _, agent_view.Unavailable -> 7
  }
}

fn admits(filter: Filter, row: Row) -> Bool {
  case filter, row.status {
    AllAgents, _ -> True
    AttentionAgents, status -> agent_view.needs_attention(status)
    WorkingAgents, agent_view.Working | WorkingAgents, agent_view.Waiting ->
      True
    SettledAgents, agent_view.Finished
    | SettledAgents, agent_view.Idle
    | SettledAgents, agent_view.Unavailable
    -> True
    WorkingAgents, _ | SettledAgents, _ -> False
  }
}

/// Moves to the next filter, keeping the selected identity if the new
/// filter still shows it and otherwise selecting its first row.
///
/// ## Examples
///
/// ```gleam
/// assert agents.cycle_filter(agents.inspect("main"), [], agents.Next).filter
///   == agents.AttentionAgents
/// ```
@internal
pub fn cycle_filter(
  inspector: Inspector,
  rows: List(Row),
  direction: Direction,
) -> Inspector {
  let filter = case direction, inspector.filter {
    Next, AllAgents -> AttentionAgents
    Next, AttentionAgents -> WorkingAgents
    Next, WorkingAgents -> SettledAgents
    Next, SettledAgents -> AllAgents
    Previous, AllAgents -> SettledAgents
    Previous, AttentionAgents -> AllAgents
    Previous, WorkingAgents -> AttentionAgents
    Previous, SettledAgents -> WorkingAgents
  }
  let shown = listed(rows, filter)
  let selected = case
    list.any(shown, fn(row) { row.id == inspector.selected }),
    shown
  {
    True, _ | False, [] -> inspector.selected
    False, [first, ..] -> first.id
  }
  Inspector(..inspector, filter:, selected:, scroll: 0)
}

/// Moves by identity through the rows the list draws; a missing selection
/// starts at the first.
///
/// ## Examples
///
/// ```gleam
/// assert agents.navigate(agents.inspect("gone"), [], agents.Next).selected == "gone"
/// ```
@internal
pub fn navigate(
  inspector: Inspector,
  rows: List(Row),
  direction: Direction,
) -> Inspector {
  let rows = listed(rows, inspector.filter)
  let index = row_index(rows, inspector.selected)
  let selected = case
    direction,
    list.any(rows, fn(row) { row.id == inspector.selected })
  {
    _, False -> 0
    Next, True -> move_selection(index, list.length(rows), True)
    Previous, True -> move_selection(index, list.length(rows), False)
  }
  case list.first(list.drop(rows, selected)) {
    Ok(row) ->
      Inspector(..inspector, selected: row.id, scroll: 0, message: None)
    Error(Nil) -> inspector
  }
}

/// Visits the next drawn row with captured attention evidence.
///
/// ## Examples
///
/// ```gleam
/// assert agents.next_attention(agents.inspect("main"), []).selected == "main"
/// ```
@internal
pub fn next_attention(inspector: Inspector, rows: List(Row)) -> Inspector {
  let rows = listed(rows, inspector.filter)
  let index = row_index(rows, inspector.selected)
  let ordered =
    list.append(list.drop(rows, index + 1), list.take(rows, index + 1))
  case list.find(ordered, fn(row) { agent_view.needs_attention(row.status) }) {
    Ok(row) ->
      Inspector(..inspector, selected: row.id, scroll: 0, message: None)
    Error(Nil) -> inspector
  }
}

/// Renders a list and detail workspace whose footer names the unchanged
/// recipient, with no figures or messages beside the rows.
///
/// The background covers every cell, including padding and short content. Detail
/// scrolling never scrolls the roster or moves the selection.
///
/// ## Examples
///
/// ```gleam
/// // agents.render_overlay(buffer, screen, rows, "main", agents.inspect("worker"))
/// ```
pub fn render_overlay(
  buf: buffer.Buffer,
  screen: Rect,
  rows: List(Row),
  active: String,
  inspector: Inspector,
) -> buffer.Buffer {
  render_inspection(buf, screen, rows, active, inspector, no_facts(), None)
}

/// Renders the workspace, with a read-only detail supplied by the owning
/// model at its actual width for every view but Activity.
///
/// ## Examples
///
/// ```gleam
/// // agents.render_inspection(buf, area, rows, active, inspector, facts, Some(content))
/// ```
@internal
pub fn render_inspection(
  buf: buffer.Buffer,
  screen: Rect,
  rows: List(Row),
  active: String,
  inspector: Inspector,
  facts: Facts,
  content: Option(fn(Rect) -> List(span.Line)),
) -> buffer.Buffer {
  case screen.size.height < 10 {
    True -> render_compact_inspection(buf, screen, rows, inspector, content)
    False ->
      render_full_inspection(
        buf,
        screen,
        rows,
        active,
        inspector,
        facts,
        content,
      )
  }
}

// Where each part of a full workspace goes. Computed in one place because
// the detail renderers are handed `detail` before they draw, through
// `inspection_detail_area`, and must be handed the rectangle the frame
// really gives them.
type Geometry {
  Geometry(
    area: Rect,
    arrangement: Arrangement,
    list: Rect,
    divider: Rect,
    detail: Rect,
    footer: Rect,
  )
}

// Whether the detail sits beside the list or under it.
type Arrangement {
  Beside
  Stacked
}

/// The narrowest inside width that puts the detail beside the list.
const beside_width = 96

fn geometry_for(screen: Rect, shown: Int, tallest: Int) -> Geometry {
  let width = int.max(1, int.min(136, screen.size.width - 2))
  let height = int.max(1, int.min(screen.size.height, tallest))
  let area =
    geometry.rect_new(
      screen.position.x + { screen.size.width - width } / 2,
      screen.position.y,
      width,
      height,
    )
  let inside = block.inner(area, workspace_frame([]))
  let arrangement = case inside.size.width >= beside_width {
    True -> Beside
    False -> Stacked
  }

  // The footer names the recipient on a row of its own above the keys,
  // since the workspace covers the composer that would otherwise say it. A
  // blank row separates it from the body.
  let footer_rows = 2
  let body_height = int.max(0, inside.size.height - footer_rows - 1)
  let x = inside.position.x
  let y = inside.position.y
  let footer =
    geometry.rect_new(x, y + body_height + 1, inside.size.width, footer_rows)
  case arrangement {
    Beside -> {
      let list_width = agent_row.table_width
      Geometry(
        area:,
        arrangement:,
        list: geometry.rect_new(x, y, list_width, body_height),
        divider: geometry.rect_new(x + list_width + 1, y, 1, body_height),
        detail: geometry.rect_new(
          x + list_width + 3,
          y,
          int.max(0, inside.size.width - list_width - 3),
          body_height,
        ),
        footer:,
      )
    }

    // The stacked list takes its heading and as many rows as there are
    // agents, up to a third of the body, so the detail keeps the rest.
    Stacked -> {
      let list_height =
        int.min(1 + int.max(1, shown), int.max(2, body_height / 3 + 1))
      Geometry(
        area:,
        arrangement:,
        list: geometry.rect_new(x, y, inside.size.width, list_height),
        divider: geometry.rect_new(x, y + list_height, inside.size.width, 1),
        detail: geometry.rect_new(
          x,
          y + list_height + 1,
          inside.size.width,
          int.max(0, body_height - list_height - 1),
        ),
        footer:,
      )
    }
  }
}

/// Returns the exact rectangle supplied to the selected detail renderer.
///
/// The rows decide how tall a stacked list is, so they are needed to know
/// where the detail below it starts.
///
/// ## Examples
///
/// ```gleam
/// // agents.inspection_detail_area(geometry.rect_new(0, 0, 80, 24), rows, inspector)
/// ```
@internal
pub fn inspection_detail_area(
  screen: Rect,
  rows: List(Row),
  inspector: Inspector,
) -> Rect {
  case screen.size.height < 10 {
    True ->
      geometry.rect_new(
        0,
        0,
        screen.size.width,
        int.max(0, screen.size.height - 2),
      )
    False -> {
      let shape =
        geometry_for(
          screen,
          list.length(listed(rows, inspector.filter)),
          screen.size.height,
        )
      geometry.rect_new(
        0,
        0,
        shape.detail.size.width,
        int.max(0, shape.detail.size.height - detail_heading_rows(shape)),
      )
    }
  }
}

// The rows above a supplied detail: the view tabs, and beside the list a
// blank row under them.
fn detail_heading_rows(shape: Geometry) -> Int {
  case shape.arrangement {
    Beside -> 2
    Stacked -> 1
  }
}

// At short heights, framing would consume the entire body. Keep the selected
// identity and navigation fixed while the remaining rows scroll the detail.
fn render_compact_inspection(
  buf: buffer.Buffer,
  area: Rect,
  rows: List(Row),
  inspector: Inspector,
  content: Option(fn(Rect) -> List(span.Line)),
) -> buffer.Buffer {
  let height = int.max(0, area.size.height - 2)
  let #(identity, body) = case
    list.find(rows, fn(row) { row.id == inspector.selected })
  {
    Error(Nil) -> #("Selected strand unavailable", [])
    Ok(row) -> #(
      "▸ " <> row.name <> " · " <> agent_view.label(row.status),
      case content {
        Some(render) -> render(geometry.rect_new(0, 0, area.size.width, height))
        None ->
          wrapped(
            row.task <> "\n" <> row.activity,
            area.size.width,
            theme.overlay_plain(),
          )
      },
    )
  }
  let offset = case inspector.detail {
    Messages -> 0
    Overview | Notes | Collaboration ->
      int.min(inspector.scroll, int.max(0, list.length(body) - height))
  }
  paragraph.render_styled(buffer.clear(buf, area), area, [
    line(fit(identity, area.size.width), theme.overlay_signal()),
    ..list.append(list.take(list.drop(body, offset), height), [
      hints(compact_hints(inspector), area.size.width),
    ])
  ])
}

fn render_full_inspection(
  buf: buffer.Buffer,
  screen: Rect,
  rows: List(Row),
  active: String,
  inspector: Inspector,
  facts: Facts,
  content: Option(fn(Rect) -> List(span.Line)),
) -> buffer.Buffer {
  let shown = listed(rows, inspector.filter)
  let lines = list.map(shown, agent_roster.describe(facts.roster, _))

  // The frame is as tall as what it shows: the taller of the list and the
  // Activity detail, with its border, footer and the gap above the footer.
  // A view another module draws has no length known here, and a stacked
  // workspace is narrow enough to want every row, so both take the screen.
  let full = geometry_for(screen, list.length(shown), screen.size.height)
  let tallest = case full.arrangement, content {
    Beside, None -> {
      let detail =
        list.length(detail_rows(full, rows, lines, inspector, facts, content))
      int.max(list.length(shown) + 1, detail) + 5
    }
    Beside, Some(_) | Stacked, _ -> screen.size.height
  }
  let shape = geometry_for(screen, list.length(shown), tallest)

  // etui's background fill covers the area inside the padding only, so the
  // padding cells are given the modal background first; without it a column
  // of terminal background runs down each side inside the border.
  let painted =
    buf
    |> buffer.clear(screen)
    |> buffer.set_style(shape.area, theme.overlay_plain())
    |> block.render(shape.area, workspace_frame(rows))
    |> paragraph.render_styled(
      shape.list,
      list_lines(rows, lines, inspector, active, shape.list),
    )
    |> paragraph.render_styled(shape.divider, divider_lines(shape))
    |> render_detail(shape, rows, lines, inspector, facts, content)
  paragraph.render_styled(
    painted,
    shape.footer,
    footer_lines(shape, active, inspector),
  )
}

// The rule between list and detail: a column beside, a row when stacked.
fn divider_lines(shape: Geometry) -> List(span.Line) {
  let rule = style.new(theme.divider, theme.graphite, style.none())
  case shape.arrangement {
    Beside ->
      list.repeat(
        span.line_new([span.span_styled("│", rule)]),
        shape.divider.size.height,
      )
    Stacked -> [
      span.line_new([
        span.span_styled(string.repeat("─", shape.divider.size.width), rule),
      ]),
    ]
  }
}

// The footer's rows. Beside the list a first row names the recipient the
// composer keeps, so a reader never takes browsing for retargeting; a
// stacked workspace has room only for the keys.
fn footer_lines(
  shape: Geometry,
  active: String,
  inspector: Inspector,
) -> List(span.Line) {
  let width = shape.footer.size.width

  // The recipient row is quiet with the recipient itself in bold paper:
  // amber is kept for what asks the operator to act.
  let target = fit(text_hygiene.single_line(active), int.max(0, width / 3))
  let recipient =
    span.line_new([
      span.span_styled("To: ", theme.overlay_quiet()),
      span.span_styled(
        target,
        style.new(theme.paper, theme.graphite, style.bold()),
      ),
      span.span_styled(
        fit(
          case inspector.focus {
            Browsing -> " · Enter opens the selected transcript"
            Composing -> " · typing in the composer below"
          },
          int.max(0, width - 4 - text.cell_width(target)),
        ),
        theme.overlay_quiet(),
      ),
    ])
  case shape.arrangement {
    Beside -> [recipient, hints(full_hints(inspector, active), width)]
    Stacked -> [recipient, hints(compact_hints(inspector), width)]
  }
}

fn full_hints(inspector: Inspector, active: String) -> List(String) {
  case inspector.focus, inspector.detail {
    Composing, _ -> [
      "Enter submits to " <> text_hygiene.single_line(active),
      "Tab changes delivery",
      "Esc returns to the list",
    ]
    Browsing, Overview -> [
      "↑↓ select",
      "n next attention",
      "a review",
      "1-4 view",
      "Tab filter",
      "w write",
      "Esc close",
    ]
    Browsing, Messages -> [
      "↑↓ select",
      "[/] message",
      "o sender",
      "PgUp/Dn body",
      "1-4 view",
      "Esc close",
    ]
    Browsing, Notes -> [
      "↑↓ select",
      "[/] note",
      "r refresh",
      "PgUp/Dn scroll",
      "1-4 view",
      "Esc close",
    ]
    Browsing, Collaboration -> [
      "↑↓ select",
      "PgUp/Dn scroll",
      "1-4 view",
      "Tab filter",
      "Esc close",
    ]
  }
}

fn compact_hints(inspector: Inspector) -> List(String) {
  case inspector.focus, inspector.detail {
    Composing, _ -> ["Enter submits", "Esc returns to the list"]
    Browsing, Overview -> [
      "↑↓",
      "Enter open",
      "n attention",
      "1-4",
      "Tab filter",
      "Esc",
    ]
    Browsing, Messages -> ["↑↓", "[/] message", "o sender", "Pg body", "Esc"]
    Browsing, Notes -> ["↑↓", "[/] note", "r refresh", "Pg scroll", "Esc"]
    Browsing, Collaboration -> ["↑↓", "Pg scroll", "1-4", "Esc"]
  }
}

// Joins key hints with ` · `, skipping a hint that does not fit rather than
// cutting it in half, so every hint drawn names a whole key and action.
fn hints(items: List(String), width: Int) -> span.Line {
  let joined =
    list.fold(items, "", fn(drawn, item) {
      let next = case drawn {
        "" -> item
        _ -> drawn <> " · " <> item
      }
      case text.cell_width(next) <= width {
        True -> next
        False -> drawn
      }
    })
  line(joined, theme.overlay_quiet())
}

fn workspace_frame(rows: List(Row)) {
  block.block_new()
  |> block.with_border(block.Rounded)
  |> block.with_colors(theme.divider, theme.graphite)
  |> block.with_bg_fill
  |> block.with_title_styled(
    [span.span_styled(" " <> title(rows) <> " ", theme.overlay_current())],
    block.Top,
  )
  |> block.with_padding(0, 0, 1, 1)
}

// The frame's title counts what the operator would ask first: how many
// agents, how many are working, and how many need them.
fn title(rows: List(Row)) -> String {
  let working =
    list.count(rows, fn(row) {
      row.status == agent_view.Working || row.status == agent_view.Waiting
    })
  let attention =
    list.count(rows, fn(row) { agent_view.needs_attention(row.status) })
  "AGENT WORKSPACE · "
  <> plural(list.length(rows), "agent", "agents")
  <> " · "
  <> int.to_string(working)
  <> " working · "
  <> int.to_string(attention)
  <> case attention {
    1 -> " needs you"
    _ -> " need you"
  }
}

fn plural(count: Int, one: String, many: String) -> String {
  int.to_string(count)
  <> " "
  <> case count {
    1 -> one
    _ -> many
  }
}

// The list: its heading, then a window of rows that keeps the selected one
// on screen.
fn list_lines(
  rows: List(Row),
  lines: List(agent_roster.Line),
  inspector: Inspector,
  active: String,
  area: Rect,
) -> List(span.Line) {
  let heading = list_heading(rows, lines, inspector.filter, area.size.width)
  let room = int.max(1, area.size.height - 1)
  let index =
    lines
    |> list.index_map(fn(line, index) { #(line.id, index) })
    |> list.key_find(inspector.selected)
    |> result.unwrap(0)
  let #(visible, above, below) = counted_window(lines, index, room)
  let body = case visible, inspector.filter, rows {
    [], AllAgents, [] -> [line("   No agents yet.", theme.overlay_quiet())]
    [], _, _ -> [
      line(
        "   No agents match this filter. Tab shows the next one.",
        theme.overlay_quiet(),
      ),
    ]
    _, _, _ ->
      agent_row.rows(
        visible,
        agent_row.TableRow,
        area.size.width,
        theme.graphite,
        fn(line) {
          case line.id == inspector.selected, line.id == active {
            True, _ -> agent_row.Cursor
            False, True -> agent_row.Viewing
            False, False -> agent_row.Unmarked
          }
        },
      )
  }
  list.flatten([
    [heading],
    more_row(above, "↑", "above"),
    body,
    more_row(below, "↓", "below"),
  ])
}

// The rows a list shows when it is taller than its room, with how many it
// cut above and below. A side that cuts rows gives up one row to say so,
// as the session picker's list does, so a list that ends at the frame never
// reads as all the agents there are.
fn counted_window(
  lines: List(a),
  selected: Int,
  room: Int,
) -> #(List(a), Int, Int) {
  let total = list.length(lines)
  case total <= room || room < 3 {
    True -> {
      let #(visible, offset) = selection_window(lines, selected, room)
      #(visible, offset, int.max(0, total - offset - list.length(visible)))
    }
    False -> {
      let #(first, offset) = selection_window(lines, selected, room - 1)
      let #(visible, offset) = case offset > 0, offset + room - 1 < total {
        True, True -> selection_window(lines, selected, room - 2)
        True, False | False, True | False, False -> #(first, offset)
      }
      #(visible, offset, int.max(0, total - offset - list.length(visible)))
    }
  }
}

fn more_row(count: Int, arrow: String, side: String) -> List(span.Line) {
  case count {
    0 -> []
    count -> [
      line(
        "   " <> arrow <> " " <> int.to_string(count) <> " more " <> side,
        theme.overlay_quiet(),
      ),
    ]
  }
}

// The list's heading: what the filter shows and how many. How many need the
// operator is in the frame's title, and those rows are red, so the heading
// does not say it a third time.
fn list_heading(
  rows: List(Row),
  lines: List(agent_roster.Line),
  filter: Filter,
  width: Int,
) -> span.Line {
  let shown = int.to_string(list.length(lines))
  let all = int.to_string(list.length(rows))
  let #(label, count) = case filter {
    AllAgents -> #("AGENTS", " · " <> shown)
    AttentionAgents -> #("NEED YOU", " · " <> shown <> " of " <> all)
    WorkingAgents -> #("WORKING", " · " <> shown <> " of " <> all)
    SettledAgents -> #("SETTLED", " · " <> shown <> " of " <> all)
  }
  let left = " " <> label
  span.line_new([
    span.span_styled(
      fit(left, width),
      style.new(theme.quiet, theme.graphite, style.bold()),
    ),
    span.span_styled(
      fit(count, width - text.cell_width(left)),
      theme.overlay_quiet(),
    ),
  ])
}

fn render_detail(
  buf: buffer.Buffer,
  shape: Geometry,
  rows: List(Row),
  lines: List(agent_roster.Line),
  inspector: Inspector,
  facts: Facts,
  content: Option(fn(Rect) -> List(span.Line)),
) -> buffer.Buffer {
  let area = shape.detail
  let drawn = detail_rows(shape, rows, lines, inspector, facts, content)
  let offset = case inspector.detail {
    Messages -> 0
    Overview | Notes | Collaboration ->
      int.min(
        inspector.scroll,
        int.max(0, list.length(drawn) - area.size.height),
      )
  }
  let heading = case shape.arrangement {
    Beside -> 2
    Stacked -> 1
  }

  // The tabs stay put while the body scrolls under them, and a section
  // label whose body the frame cut off is not drawn on its own.
  let shown =
    list.append(
      list.take(drawn, heading),
      drawn
        |> list.drop(heading + offset)
        |> list.take(area.size.height - heading),
    )
    |> without_hanging_label
  paragraph.render_styled(buf, area, shown)
}

// The detail's rows from the top: the view tabs, then the selected view.
fn detail_rows(
  shape: Geometry,
  rows: List(Row),
  lines: List(agent_roster.Line),
  inspector: Inspector,
  facts: Facts,
  content: Option(fn(Rect) -> List(span.Line)),
) -> List(span.Line) {
  let area = shape.detail
  let heading = case shape.arrangement {
    Beside -> [tabs(inspector.detail, area.size.width), span.line_new([])]
    Stacked -> [tabs(inspector.detail, area.size.width)]
  }
  let compact = case shape.arrangement {
    Beside -> Spacious
    Stacked -> Compact
  }
  let body = case list.find(rows, fn(row) { row.id == inspector.selected }) {
    Error(Nil) -> [
      line("Selected strand unavailable", theme.overlay_signal()),
      ..wrapped(
        "Its draft remains with its original recipient. Use ↑↓ to inspect another strand.",
        area.size.width,
        theme.overlay_plain(),
      )
    ]
    Ok(row) ->
      case content {
        Some(render) ->
          render(geometry.rect_new(
            0,
            0,
            area.size.width,
            int.max(0, area.size.height - list.length(heading)),
          ))
        None -> {
          let figures =
            list.find(lines, fn(line) { line.id == row.id })
            |> result.lazy_unwrap(fn() {
              agent_roster.describe(facts.roster, row)
            })

          // The heading names the agent as its list row does, twins' digest
          // heads included, so the two can be matched at a glance.
          let name =
            dict.get(agent_row.labels(lines), row.id)
            |> result.unwrap(figures.name)
          detail_lines(
            row,
            name,
            figures,
            facts.messages,
            area.size.width,
            compact,
          )
        }
      }
  }
  list.append(heading, body)
}

// Drops the trailing blanks and section labels a cut leaves, so the last
// row drawn is never a heading with nothing under it.
fn without_hanging_label(rows: List(span.Line)) -> List(span.Line) {
  rows
  |> list.reverse
  |> list.drop_while(fn(row) {
    case row.spans {
      [] -> True
      [only] -> only.content == "" || only.style == label_style()
      [_, _, ..] -> False
    }
  })
  |> list.reverse
}

// The view tabs, named in full when there is room and shortened when not.
fn tabs(detail: Detail, width: Int) -> span.Line {
  let names = case width >= 56 {
    True -> [
      #(Overview, "1 Activity"),
      #(Messages, "2 Messages"),
      #(Notes, "3 Notes"),
      #(Collaboration, "4 Collaborate"),
    ]
    False -> [
      #(Overview, "1 Activity"),
      #(Messages, "2 Msgs"),
      #(Notes, "3 Notes"),
      #(Collaboration, "4 Collab"),
    ]
  }
  span.line_new(
    list.flat_map(names, fn(pair) {
      let look = case pair.0 == detail {
        True -> style.new(theme.paper, theme.raised, style.bold())
        False -> theme.overlay_quiet()
      }
      [
        span.span_styled(" " <> pair.1 <> " ", look),
        span.span_styled(" ", theme.overlay_quiet()),
      ]
    }),
  )
}

// How much a detail spreads out: beside the list it has blank rows between
// its sections and shows every one; stacked under the list it keeps the
// task and what the agent is doing now.
type Spacing {
  Spacious
  Compact
}

// The Activity detail: the agent's name and state, then its sections, each
// saying one thing once. A failed agent leads with its error and says the
// error is not repeated, because the transcript Enter opens already has it.
fn detail_lines(
  row: Row,
  name: String,
  figures: agent_roster.Line,
  messages: List(agent_messages.Item),
  width: Int,
  spacing: Spacing,
) -> List(span.Line) {
  let gap = case spacing {
    Spacious -> [span.line_new([])]
    Compact -> []
  }
  let #(glyph, tone) = agent_row.glyph(row.id, row.status, theme.graphite)
  let title = [
    span.line_new([
      span.span_styled(glyph <> " ", tone),
      span.span_styled(
        agent_row.cut_middle(name, int.max(0, width - 2)),
        style.new(theme.paper, theme.graphite, style.bold()),
      ),
    ]),
    state_line(row, figures, width),
  ]
  let task_rows = case spacing {
    Spacious -> 4
    Compact -> 2
  }
  let task = [label_line("TASK"), ..clamped(row.task, task_rows, width)]
  let now = [label_line("NOW"), ..now_lines(row, width)]
  let rest = case spacing {
    Compact -> []
    Spacious ->
      list.flatten([
        message_lines(row, messages, width),
        table_lines(row, width),
        [span.line_new([])],
        identity_lines(row, width),
      ])
  }
  list.flatten([title, gap, task, [span.line_new([])], now, rest])
}

// The state word in the glyph's colour, then the figures and the model.
fn state_line(row: Row, figures: agent_roster.Line, width: Int) -> span.Line {
  let facts =
    [
      option.map(figures.elapsed_s, agent_roster.duration),
      option.map(figures.tokens, fn(count) {
        agent_row.compact_count(count) <> " ctx"
      }),
      short_model(row.model),
    ]
    |> option.values
  let rest = case facts {
    [] -> ""
    _ -> " · " <> string.join(facts, " · ")
  }
  let word = string.lowercase(agent_view.label(row.status))
  span.line_new([
    span.span_styled(word, agent_row.status_style(row.status, theme.graphite)),
    span.span_styled(
      agent_row.cut(rest, int.max(0, width - text.cell_width(word))),
      theme.overlay_quiet(),
    ),
  ])
}

// A model reads by its last path segment; an unknown one is left out
// rather than drawn as a placeholder sentence.
fn short_model(model: String) -> Option(String) {
  case string.contains(model, " ") || model == "" {
    True -> None
    False ->
      string.split(model, "/")
      |> list.last
      |> option.from_result
      |> option.map(text_hygiene.single_line)
  }
}

// What the agent is doing now. A pending approval leads with the request
// and the key that reviews it; nothing here decides it. A failure leads
// with its error.
fn now_lines(row: Row, width: Int) -> List(span.Line) {
  case row.approvals, row.status {
    [_, ..], _ ->
      clamped_styled(
        "Needs approval: " <> row.decision,
        2,
        width,
        style.new(theme.danger, theme.graphite, style.bold()),
      )
      |> list.append([
        span.line_new([
          span.span_styled(
            "a",
            style.new(theme.signal, theme.graphite, style.bold()),
          ),
          span.span_styled(
            agent_row.cut(" reviews the exact request", width - 1),
            theme.overlay_quiet(),
          ),
        ]),
        line(
          agent_row.cut("Nothing is approved here.", width),
          theme.overlay_quiet(),
        ),
      ])
    [], agent_view.Failed ->
      list.append(
        clamped_styled(
          "× " <> row.activity,
          2,
          width,
          style.new(theme.danger, theme.graphite, style.bold()),
        ),
        clamped_styled(
          "Enter opens its transcript; the error is not repeated here",
          2,
          width,
          theme.overlay_quiet(),
        ),
      )
    [], _ -> clamped(row.activity, 2, width)
  }
}

// The latest sends in and out of the agent, newest first: the direction,
// the other strand, and the body cut at a word.
fn message_lines(
  row: Row,
  messages: List(agent_messages.Item),
  width: Int,
) -> List(span.Line) {
  case
    agent_messages.for_strand(messages, row.id)
    |> list.take(2)
    |> list.reverse
  {
    [] -> []
    latest -> [
      span.line_new([]),
      label_line("LATEST MESSAGES"),
      ..list.map(latest, fn(item) {
        let #(arrow, other) = case item.target == row.id {
          True -> #("← ", item.source)
          False -> #("→ ", item.target)
        }
        let other =
          agent_row.cut_middle(agent_roster.short_name(other), width / 3)
        span.line_new([
          span.span_styled(
            arrow,
            style.new(theme.current, theme.graphite, style.bold()),
          ),
          span.span_styled(
            other <> "  ",
            style.new(theme.paper, theme.graphite, style.bold()),
          ),
          span.span_styled(
            agent_row.cut(
              item.body,
              int.max(0, width - 2 - text.cell_width(other) - 2),
            ),
            theme.overlay_plain(),
          ),
        ])
      })
    ]
  }
}

// The inbox and the tools, as a two-row table with one key column.
fn table_lines(row: Row, width: Int) -> List(span.Line) {
  let inbox = case string.trim(row.pending) {
    "" -> []
    pending -> [table_row("INBOX", pending, width)]
  }
  let tools = case row.recent {
    [] -> []
    recent -> [table_row("TOOLS", tally(recent), width)]
  }
  case list.append(inbox, tools) {
    [] -> []
    table -> [span.line_new([]), ..table]
  }
}

// Repeated tool names fold into one with a count, `read ×3`, in the order
// each first appears.
fn tally(names: List(String)) -> String {
  let counts =
    list.fold(names, dict.new(), fn(counts, name) {
      dict.upsert(counts, name, fn(seen) { option.unwrap(seen, 0) + 1 })
    })
  names
  |> list.unique
  |> list.map(fn(name) {
    case dict.get(counts, name) {
      Ok(count) if count > 1 -> name <> " ×" <> int.to_string(count)
      Ok(_) | Error(Nil) -> name
    }
  })
  |> string.join(" · ")
}

fn table_row(key: String, value: String, width: Int) -> span.Line {
  span.line_new([
    span.span_styled(
      text.pad_right(key, 7),
      style.new(theme.quiet, theme.graphite, style.bold()),
    ),
    span.span_styled(
      agent_row.cut(value, int.max(0, width - 7)),
      theme.overlay_plain(),
    ),
  ])
}

// The identity, in the dimmest line, and the advisor's role under it.
fn identity_lines(row: Row, width: Int) -> List(span.Line) {
  let operation = case row.operation {
    Some(operation) -> ["op " <> string.slice(operation, 0, 6)]
    None -> []
  }
  let rest =
    [operation, option.values([short_model(row.model)])]
    |> list.flatten
    |> list.map(fn(part) { " · " <> part })
    |> string.concat

  // The identity is cut in the middle so its digest's tail survives, and
  // the operation and model after it are never cut.
  let identity =
    agent_row.cut_middle(row.id, int.max(8, width - text.cell_width(rest)))
    <> rest
  let role = case row.id {
    "advisor" -> [
      line(
        "Advisor · observes and reviews the primary strand.",
        style.new(theme.advisor, theme.graphite, style.none()),
      ),
    ]
    _ -> []
  }
  [line(fit(identity, width), theme.overlay_quiet()), ..role]
}

fn label_line(value: String) -> span.Line {
  line(value, label_style())
}

// The one style every section label is drawn in, which is also how a cut
// recognises a label it would leave hanging.
fn label_style() -> style.Style {
  style.new(theme.quiet, theme.graphite, style.bold())
}

// At most `rows` wrapped lines of plain text. A longer value ends its last
// row at a word with an ellipsis and a quiet line says where the rest is.
fn clamped(value: String, rows: Int, width: Int) -> List(span.Line) {
  clamped_styled(value, rows, width, theme.overlay_plain())
}

fn clamped_styled(
  value: String,
  rows: Int,
  width: Int,
  look: style.Style,
) -> List(span.Line) {
  let lines =
    value
    |> text_hygiene.multiline
    |> string.split("\n")
    |> list.flat_map(fn(row) { text.wrap(row, int.max(1, width)) })
  case list.drop(lines, rows) {
    [] -> list.map(lines, line(_, look))
    [_, ..] ->
      list.append(list.take(lines, rows - 1) |> list.map(line(_, look)), [
        line(
          agent_row.cut(string.join(list.drop(lines, rows - 1), " "), width),
          look,
        ),
        line(
          agent_row.cut("The rest is in its transcript · Enter", width),
          theme.overlay_quiet(),
        ),
      ])
  }
}

fn wrapped(
  value: String,
  width: Int,
  appearance: style.Style,
) -> List(span.Line) {
  value
  |> text_hygiene.multiline
  |> string.split("\n")
  |> list.flat_map(fn(row) { text.wrap(row, int.max(1, width)) })
  |> list.map(fn(row) { line(row, appearance) })
}

/// The colour a status is drawn in, on a given row background
/// (`agent_row.status_style`).
///
/// ## Examples
///
/// ```gleam
/// // agents.status_style(agent_view.Working, theme.raised)
/// ```
@internal
pub fn status_style(
  status: agent_view.Status,
  background: style.Color,
) -> style.Style {
  agent_row.status_style(status, background)
}

/// The glyph that carries a status without colour (`agent_row.status_mark`).
///
/// ## Examples
///
/// ```gleam
/// assert agents.status_mark(agent_view.Failed) == "×"
/// ```
@internal
pub fn status_mark(status: agent_view.Status) -> String {
  agent_row.status_mark(status)
}

fn line(value: String, appearance: style.Style) -> span.Line {
  span.line_new([span.span_styled(value, appearance)])
}

fn fit(value: String, width: Int) -> String {
  text.truncate(text_hygiene.single_line(value), int.max(0, width), "…")
}

fn row_index(rows: List(Row), selected: String) -> Int {
  rows
  |> list.index_map(fn(row, index) { #(row.id, index) })
  |> list.key_find(selected)
  |> result.unwrap(0)
}

/// Counts only states justified by the shared projection.
///
/// ## Examples
///
/// ```gleam
/// assert agents.summary_rows([]) == "0 agents · 0 working · 0 attention"
/// ```
@internal
pub fn summary_rows(rows: List(Row)) -> String {
  int.to_string(list.length(rows))
  <> " agents · "
  <> int.to_string(
    list.count(rows, fn(row) {
      row.status == agent_view.Working || row.status == agent_view.Waiting
    }),
  )
  <> " working · "
  <> int.to_string(
    list.count(rows, fn(row) { agent_view.needs_attention(row.status) }),
  )
  <> " attention"
}

/// Returns the legacy phase summary for older recordings.
///
/// ## Examples
///
/// ```gleam
/// assert agents.summary([]) == "0 live / 0 agents"
/// ```
pub fn summary(strands: List(Strand)) -> String {
  int.to_string(list.count(strands, fn(strand) { strand.live_phase != None }))
  <> " live / "
  <> int.to_string(list.length(strands))
  <> " agents"
}

/// Slices rows so the selected position remains visible.
@internal
pub fn selection_window(
  rows: List(a),
  selected: Int,
  visible_count: Int,
) -> #(List(a), Int) {
  let max_offset = int.max(0, list.length(rows) - visible_count)
  let offset = int.min(int.max(0, selected - { visible_count / 2 }), max_offset)
  #(rows |> list.drop(offset) |> list.take(visible_count), offset)
}

/// Moves a positional legacy selector and wraps at either edge.
@internal
pub fn move_selection(selected: Int, count: Int, down: Bool) -> Int {
  case count <= 0, down, selected {
    True, _, _ -> 0
    False, True, selected if selected >= count - 1 -> 0
    False, True, selected -> selected + 1
    False, False, selected if selected <= 0 -> count - 1
    False, False, selected -> selected - 1
  }
}

/// Resolves a legacy selector to its stable strand identity.
@internal
pub fn selected_strand(strands: List(Strand), selected: Int) -> Option(String) {
  strands
  |> list.drop(selected)
  |> list.first
  |> result.map(fn(strand) { strand.id })
  |> option.from_result
}
