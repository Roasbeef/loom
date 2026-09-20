//// The agent workspace separates inspection from the message recipient.
////
//// The rail and workspace share bounded, evidence-based rows. Navigation holds
//// a stable strand identity, while only the explicit Open action can change
//// the transcript and composer. Narrow terminals stack the selected row above
//// its detail; wide terminals retain a roster alongside that same detail.

import etui/buffer
import etui/geometry.{type Rect, Fill, Length}
import etui/span
import etui/style
import etui/text
import etui/widgets/block
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import gleam/string
import tui/agent_view.{type Row}
import tui/protocol.{type Strand}
import tui/text_hygiene
import tui/theme

/// Inspection never owns the composer's recipient or draft.
@internal
pub type Inspector {
  Inspector(
    /// Stable strand identity, retained even if the strand disappears.
    selected: String,
    /// Independent scroll position within the selected detail.
    scroll: Int,
  )
}

/// Direction is explicit at navigation call sites.
@internal
pub type Direction {
  /// Previous row, wrapping at the beginning.
  Previous

  /// Next row, wrapping at the end.
  Next
}

/// Opens inspection on the current transcript without changing its draft.
///
/// ## Examples
///
/// ```gleam
/// assert agents.inspect("main") == agents.Inspector("main", 0)
/// ```
@internal
pub fn inspect(active: String) -> Inspector {
  Inspector(active, 0)
}

/// Moves by identity; a missing selection starts at the next available row.
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
    Ok(row) -> inspect(row.id)
    Error(Nil) -> inspector
  }
}

/// Visits the next row with captured attention evidence without changing order.
///
/// ## Examples
///
/// ```gleam
/// assert agents.next_attention(agents.inspect("main"), []).selected == "main"
/// ```
@internal
pub fn next_attention(inspector: Inspector, rows: List(Row)) -> Inspector {
  let index = row_index(rows, inspector.selected)
  let ordered =
    list.append(list.drop(rows, index + 1), list.take(rows, index + 1))
  case list.find(ordered, fn(row) { agent_view.needs_attention(row.status) }) {
    Ok(row) -> inspect(row.id)
    Error(Nil) -> inspector
  }
}

/// Renders the compact task roster, keeping the active recipient in view.
///
/// ## Examples
///
/// ```gleam
/// // agents.render_rail(buffer, area, rows, "main")
/// ```
pub fn render_rail(
  buf: buffer.Buffer,
  area: Rect,
  rows: List(Row),
  active: String,
) -> buffer.Buffer {
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.divider, style.Default)
    |> block.with_title_styled(
      [
        span.span_styled(" AGENTS ", theme.current_bold()),
        span.span_styled("· F2 inspect ", theme.quiet_text()),
      ],
      block.Top,
    )
  let inside = block.inner(area, frame)
  let visible_count = int.max(1, { inside.size.height - 2 } / 4)
  let #(visible, _) =
    selection_window(rows, row_index(rows, active), visible_count)
  let lines = [
    line(
      summary_rows(rows) |> string.replace(" agents · ", " · "),
      theme.quiet_text(),
    ),
    span.line_plain(""),
    ..roster_lines(visible, active, active, inside.size.width, style.Default)
  ]
  buf |> block.render(area, frame) |> paragraph.render_styled(inside, lines)
}

/// Renders a roster/detail workspace whose footer names the unchanged recipient.
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
  let width = int.max(1, int.min(136, screen.size.width - 2))
  let height = int.max(1, screen.size.height - 2)
  let area = geometry.centered_rect(width, height, screen)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.current, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title_styled(
      [
        span.span_styled(" AGENT WORKSPACE ", theme.overlay_current()),
        span.span_styled(summary_rows(rows) <> " ", theme.overlay_quiet()),
      ],
      block.Top,
    )
    |> block.with_padding(0, 0, 1, 1)
  let inside = block.inner(area, frame)
  let #(content, footer) = case geometry.split_v(inside, [Fill, Length(3)]) {
    [content, footer] -> #(content, footer)
    _ -> #(inside, geometry.rect_zero())
  }
  let painted =
    buf
    |> buffer.clear(screen)
    |> block.render(area, frame)
    |> render_workspace(content, rows, active, inspector)
  let footer_lines = [
    line(
      "To: "
        <> text_hygiene.single_line(active)
        <> " · Enter opens selected transcript",
      theme.overlay_signal(),
    ),
    line(
      "↑/↓ inspect · n attention · a approval · PgUp/PgDn detail",
      theme.overlay_quiet(),
    ),
    line(
      "Esc conversation · drafts stay with their strand",
      theme.overlay_quiet(),
    ),
  ]
  paragraph.render_styled(
    painted,
    footer,
    fit_lines(footer_lines, footer.size.width),
  )
}

fn render_workspace(
  buf: buffer.Buffer,
  area: Rect,
  rows: List(Row),
  active: String,
  inspector: Inspector,
) -> buffer.Buffer {
  case area.size.width >= 96 {
    True -> {
      let parts = geometry.split_h(area, [Length(34), Length(2), Fill])
      case parts {
        [roster, _, detail] -> {
          let #(visible, _) =
            selection_window(
              rows,
              row_index(rows, inspector.selected),
              int.max(1, roster.size.height / 4),
            )
          buf
          |> paragraph.render_styled(
            roster,
            roster_lines(
              visible,
              active,
              inspector.selected,
              roster.size.width,
              theme.graphite,
            ),
          )
          |> render_detail(detail, rows, inspector)
        }
        _ -> render_detail(buf, area, rows, inspector)
      }
    }
    False -> {
      let parts = geometry.split_v(area, [Length(2), Fill])
      case parts {
        [roster, detail] -> {
          let index = row_index(rows, inspector.selected)
          let label = case list.first(list.drop(rows, index)) {
            Ok(row) if row.id == inspector.selected ->
              "▸ "
              <> row.name
              <> " · "
              <> int.to_string(index + 1)
              <> "/"
              <> int.to_string(list.length(rows))
            _ -> "▸ Selected strand unavailable"
          }
          buf
          |> paragraph.render_styled(roster, [
            line(fit(label, roster.size.width), theme.overlay_signal()),
          ])
          |> render_detail(detail, rows, inspector)
        }
        _ -> render_detail(buf, area, rows, inspector)
      }
    }
  }
}

fn render_detail(
  buf: buffer.Buffer,
  area: Rect,
  rows: List(Row),
  inspector: Inspector,
) -> buffer.Buffer {
  let lines = case list.find(rows, fn(row) { row.id == inspector.selected }) {
    Error(Nil) -> [
      line("Selected strand unavailable", theme.overlay_signal()),
      ..wrapped(
        "Its draft remains with its original recipient. Use ↑/↓ to inspect another strand.",
        area.size.width,
        theme.overlay_plain(),
      )
    ]
    Ok(row) -> detail_lines(row, area.size.width)
  }
  let offset =
    int.min(inspector.scroll, int.max(0, list.length(lines) - area.size.height))
  paragraph.render_styled(buf, area, list.drop(lines, offset))
}

fn detail_lines(row: Row, width: Int) -> List(span.Line) {
  let title = [
    line(fit(row.name, width), identity_style(row, theme.graphite)),
    line(
      fit(status_mark(row.status) <> " " <> agent_view.label(row.status), width),
      status_style(row.status, theme.graphite),
    ),
    span.line_plain(""),
  ]
  let task = section("TASK", row.task, width)
  let activity = section("CURRENT STATE", row.activity, width)
  let update = section("LATEST UPDATE", row.update, width)
  let pending = section("INPUT", row.pending, width)
  let approvals = case row.approvals {
    [] -> []
    [_, ..] ->
      wrapped(
        "Press a to review the exact pending permission request.",
        width,
        theme.overlay_signal(),
      )
  }
  let identity = section("IDENTITY", row.id <> " · " <> row.model, width)
  let role = case row.id {
    "advisor" ->
      wrapped(
        "Advisor · observes and reviews the primary strand.",
        width,
        style.new(theme.advisor, theme.graphite, style.none()),
      )
    _ -> []
  }
  list.flatten([
    title,
    task,
    activity,
    update,
    pending,
    approvals,
    identity,
    role,
  ])
}

fn section(heading: String, value: String, width: Int) -> List(span.Line) {
  [
    line(heading, theme.overlay_quiet()),
    ..list.append(wrapped(value, width, theme.overlay_plain()), [
      span.line_plain(""),
    ])
  ]
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

fn roster_lines(
  rows: List(Row),
  active: String,
  selected: String,
  width: Int,
  background: style.Color,
) -> List(span.Line) {
  case rows {
    [] -> [
      line(
        "No agents captured",
        style.new(theme.quiet, background, style.none()),
      ),
    ]
    _ ->
      list.flat_map(rows, fn(row) {
        let focus = case row.id == selected {
          True -> "▸ "
          False -> "  "
        }
        let target = case row.id == active {
          True -> " · to"
          False -> ""
        }
        let background = case row.id == selected {
          True -> theme.raised
          False -> background
        }
        let name = case row.id == selected {
          True -> style.new(theme.signal, background, style.bold())
          False -> identity_style(row, background)
        }
        let state =
          "  " <> status_mark(row.status) <> " " <> agent_view.label(row.status)
        let progress =
          " · " <> fit_tail(row.activity, width - text.cell_width(state) - 3)
        [
          line(
            focus
              <> fit_tail(row.name, width - text.cell_width(focus <> target))
              <> target |> text.pad_right(width),
            name,
          ),
          line(
            fit("  " <> row.task, width) |> text.pad_right(width),
            style.new(theme.paper, background, style.none()),
          ),
          line(
            fit(state <> progress, width) |> text.pad_right(width),
            status_style(row.status, background),
          ),
          span.line_plain(""),
        ]
      })
  }
}

fn identity_style(row: Row, background: style.Color) -> style.Style {
  let color = case row.id {
    "advisor" -> theme.advisor
    _ -> theme.current
  }
  style.new(color, background, style.bold())
}

fn status_style(
  status: agent_view.Status,
  background: style.Color,
) -> style.Style {
  let color = case status {
    agent_view.Working -> theme.current
    agent_view.Waiting | agent_view.NeedsInput | agent_view.Halted ->
      theme.signal
    agent_view.Finished -> theme.added
    agent_view.Failed -> theme.danger
    agent_view.Idle | agent_view.Unavailable -> theme.quiet
  }
  style.new(color, background, style.none())
}

fn status_mark(status: agent_view.Status) -> String {
  case status {
    agent_view.Working -> "●"
    agent_view.Waiting -> "◷"
    agent_view.NeedsInput -> "?"
    agent_view.Finished -> "✓"
    agent_view.Failed -> "×"
    agent_view.Halted -> "!"
    agent_view.Idle -> "○"
    agent_view.Unavailable -> "-"
  }
}

fn line(value: String, appearance: style.Style) -> span.Line {
  span.line_new([span.span_styled(value, appearance)])
}

fn fit(value: String, width: Int) -> String {
  text.truncate(text_hygiene.single_line(value), int.max(0, width), "…")
}

// Child identities share a long prefix, so their distinguishing suffix is
// retained. Reverse by grapheme, then truncate by terminal cell width.
fn fit_tail(value: String, width: Int) -> String {
  value
  |> text_hygiene.single_line
  |> string.reverse
  |> text.truncate(int.max(0, width), "…")
  |> string.reverse
}

fn fit_lines(lines: List(span.Line), width: Int) -> List(span.Line) {
  list.map(lines, fn(row) {
    span.line_new(
      list.map(row.spans, fn(value) {
        span.span_styled(fit(value.content, width), value.style)
      }),
    )
  })
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
