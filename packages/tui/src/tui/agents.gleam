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
import gleam/option.{type Option, None, Some}
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
    /// Keyboard owner; inspection never consumes composer text.
    focus: Focus,
    /// The selected read-only detail, independent of the composer.
    detail: Detail,
    /// Durable invocation identity for the selected observed send.
    message: Option(String),
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
/// assert agents.inspect("main").selected == "main"
/// ```
@internal
pub fn inspect(active: String) -> Inspector {
  Inspector(active, 0, Browsing, Overview, None)
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
    Ok(row) ->
      Inspector(..inspector, selected: row.id, scroll: 0, message: None)
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
    Ok(row) ->
      Inspector(..inspector, selected: row.id, scroll: 0, message: None)
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
  let workers = list.filter(rows, fn(row) { row.id != "advisor" })
  let advisor = list.filter(rows, fn(row) { row.id == "advisor" })
  let parts =
    geometry.split_v(inside, [
      Length(2),
      Fill,
      Length(case advisor {
        [] -> 0
        _ -> 5
      }),
    ])
  let painted = block.render(buf, area, frame)
  case parts {
    [summary, roster, review] -> {
      let visible_count = int.max(1, { roster.size.height - 2 } / 4)
      let #(visible, _) =
        selection_window(workers, row_index(workers, active), visible_count)
      let advisor_lines = case advisor {
        [] -> [
          line("ADVISOR", theme.quiet_text()),
          line("Not captured", theme.quiet_text()),
        ]
        _ ->
          roster_lines(
            advisor,
            active,
            active,
            review.size.width,
            style.Default,
          )
      }
      painted
      |> paragraph.render_styled(summary, [
        line(
          summary_rows(rows) |> string.replace(" agents · ", " · "),
          theme.quiet_text(),
        ),
      ])
      |> paragraph.render_styled(
        roster,
        roster_lines(visible, active, active, roster.size.width, style.Default),
      )
      |> paragraph.render_styled(review, advisor_lines)
    }
    _ -> painted
  }
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
  render_inspection(buf, screen, rows, active, inspector, None)
}

/// Renders a read-only detail supplied by the owning model at its actual width.
///
/// ## Examples
///
/// ```gleam
/// // agents.render_inspection(buf, area, rows, active, inspector, Some(content))
/// ```
@internal
pub fn render_inspection(
  buf: buffer.Buffer,
  screen: Rect,
  rows: List(Row),
  active: String,
  inspector: Inspector,
  content: Option(fn(Rect) -> List(span.Line)),
) -> buffer.Buffer {
  case screen.size.height < 10 {
    True -> render_compact_inspection(buf, screen, rows, inspector, content)
    False ->
      render_full_inspection(buf, screen, rows, active, inspector, content)
  }
}

/// Returns the exact rectangle supplied to the selected detail renderer.
///
/// ## Examples
///
/// ```gleam
/// // agents.inspection_detail_area(geometry.rect_new(0, 0, 80, 24))
/// ```
@internal
pub fn inspection_detail_area(screen: Rect) -> Rect {
  case screen.size.height < 10 {
    True ->
      geometry.rect_new(
        0,
        0,
        screen.size.width,
        int.max(0, screen.size.height - 2),
      )
    False -> {
      let width = int.max(1, int.min(136, screen.size.width - 2))
      let height = int.max(1, screen.size.height - 2)
      let area = geometry.centered_rect(width, height, screen)
      let frame = workspace_frame([])
      let inside = block.inner(area, frame)
      let content = case geometry.split_v(inside, [Fill, Length(3)]) {
        [content, _] -> content
        _ -> inside
      }
      let detail = case content.size.width >= 96 {
        True ->
          case geometry.split_h(content, [Length(34), Length(2), Fill]) {
            [_, _, detail] -> detail
            _ -> content
          }
        False ->
          case geometry.split_v(content, [Length(2), Fill]) {
            [_, detail] -> detail
            _ -> content
          }
      }
      geometry.rect_new(
        0,
        0,
        detail.size.width,
        int.max(0, detail.size.height - 2),
      )
    }
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
      line(
        case inspector.focus {
          Browsing ->
            case inspector.detail {
              Messages -> "[/] message · o sender · Pg body · Esc close"
              Notes -> "[/] note · ^g raw · Pg body · Esc close"
              Overview -> "↑↓ inspect · 1/2/3/4 view · Esc close"
              Collaboration -> "Pg scroll · Tab write · Esc close"
            }
          Composing -> "Editing composer · Esc inspects"
        },
        theme.overlay_quiet(),
      ),
    ])
  ])
}

fn render_full_inspection(
  buf: buffer.Buffer,
  screen: Rect,
  rows: List(Row),
  active: String,
  inspector: Inspector,
  content: Option(fn(Rect) -> List(span.Line)),
) -> buffer.Buffer {
  let width = int.max(1, int.min(136, screen.size.width - 2))
  let height = int.max(1, screen.size.height - 2)
  let area = geometry.centered_rect(width, height, screen)
  let frame = workspace_frame(rows)
  let inside = block.inner(area, frame)
  let detail_content = content
  let #(content, footer) = case geometry.split_v(inside, [Fill, Length(3)]) {
    [content, footer] -> #(content, footer)
    _ -> #(inside, geometry.rect_zero())
  }

  // Clearing this body rectangle leaves the real composer and footer intact.
  // The inset padding must be opaque too when underlying text is longer.
  let painted =
    buf
    |> buffer.clear(screen)
    |> block.render(area, frame)
    |> render_workspace(content, rows, active, inspector, detail_content)
  let footer_lines = [
    line(
      "To: "
        <> text_hygiene.single_line(active)
        <> case inspector.focus {
        Browsing -> " · Enter opens selected transcript"
        Composing -> " · typing in the composer below"
      },
      theme.overlay_signal(),
    ),
    line(
      case inspector.focus {
        Browsing -> "↑/↓ inspect · n attention · a review permission"
        Composing ->
          "Enter submits to the named recipient · Tab changes delivery"
      },
      theme.overlay_quiet(),
    ),
    line(
      case inspector.focus {
        Browsing ->
          case inspector.detail {
            Notes ->
              "[/] note · r refresh · PgUp/Dn scroll · Tab write · Esc close"
            Messages ->
              "[/] message · o sender · PgUp/Dn body · Tab write · Esc close"
            Overview -> "1/2/3/4 view · PgUp/Dn scroll · Tab write · Esc close"
            Collaboration ->
              "4 Collaboration · PgUp/Dn scroll · Tab write · Esc close"
          }
        Composing -> "Editing To " <> active <> " · Esc returns to roster"
      },
      theme.overlay_quiet(),
    ),
  ]
  paragraph.render_styled(
    painted,
    footer,
    fit_lines(footer_lines, footer.size.width),
  )
}

fn workspace_frame(rows: List(Row)) {
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
}

fn render_workspace(
  buf: buffer.Buffer,
  area: Rect,
  rows: List(Row),
  active: String,
  inspector: Inspector,
  content: Option(fn(Rect) -> List(span.Line)),
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
              int.max(1, { roster.size.height - 3 } / 4),
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
          |> render_detail(detail, rows, inspector, content)
        }
        _ -> render_detail(buf, area, rows, inspector, content)
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
          |> render_detail(detail, rows, inspector, content)
        }
        _ -> render_detail(buf, area, rows, inspector, content)
      }
    }
  }
}

fn render_detail(
  buf: buffer.Buffer,
  area: Rect,
  rows: List(Row),
  inspector: Inspector,
  content: Option(fn(Rect) -> List(span.Line)),
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
    Ok(row) -> {
      let heading = case inspector.detail {
        Overview -> "[1 Activity]  2 Messages  3 Notes  4 Collaborate"
        Messages -> "1 Activity  [2 Messages]  3 Notes  4 Collaborate"
        Notes -> "1 Activity  2 Messages  [3 Notes]  4 Collaborate"
        Collaboration -> "1 Activity  2 Messages  3 Notes  [4 Collaborate]"
      }
      let body = case content {
        Some(render) ->
          render(geometry.rect_new(
            0,
            0,
            area.size.width,
            int.max(0, area.size.height - 2),
          ))
        None -> detail_lines(row, area.size.width)
      }
      [
        line(fit(heading, area.size.width), theme.overlay_current()),
        span.line_plain(""),
        ..body
      ]
    }
  }
  let offset = case inspector.detail {
    Messages -> 0
    Overview | Notes | Collaboration ->
      int.min(
        inspector.scroll,
        int.max(0, list.length(lines) - area.size.height),
      )
  }
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
  let recent = case row.recent {
    [] ->
      section(
        "RECENT ACTIVITY",
        "Tool history unavailable in this capture. Enter opens the transcript.",
        width,
      )
    rows -> section("RECENT ACTIVITY", string.join(rows, "\n"), width)
  }
  let approvals = case row.approvals {
    [] -> []
    [_, ..] ->
      wrapped(
        "? PERMISSION NEEDED\n"
          <> row.decision
          <> "\nPress a to review this exact request. Nothing is approved here.",
        width,
        theme.overlay_signal(),
      )
  }

  // Provenance follows the actionable content so small terminals reach the
  // task and exact pending decision before accounting and identity metadata.
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
    approvals,
    update,
    recent,
    pending,
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
      list.index_map(rows, fn(row, index) {
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

        // Section headings distinguish roles without reordering live rows.
        let section = role_heading(row.id)
        let previous =
          list.drop(rows, index - 1)
          |> list.first
          |> result.map(fn(previous) { role_heading(previous.id) })
          |> result.unwrap("")
        let heading = case index == 0 || section != previous {
          True -> [
            line(section, style.new(theme.quiet, background, style.none())),
          ]
          False -> []
        }
        list.append(heading, [
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
        ])
      })
      |> list.flatten
  }
}

fn role_heading(id: String) -> String {
  case id {
    "main" -> "SESSION"
    "advisor" -> "ADVISOR · independent review"
    _ -> "STRANDS"
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
