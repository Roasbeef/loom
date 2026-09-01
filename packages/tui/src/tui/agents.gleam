//// Live agent and strand presentation.
////
//// Loom already publishes the durable strand set and each strand's live
//// operation phase. This module turns that existing authority into a compact
//// rail and an expanded inspector without maintaining a second lifecycle.

import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/style
import etui/widgets/block
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/protocol.{type Strand, Strand}
import tui/text_hygiene
import tui/theme

/// Renders the always-visible agent rail on wide terminals.
///
/// ## Examples
///
/// ```gleam
/// let next_buffer = agents.render_rail(buffer, area, strands, "main")
/// ```
pub fn render_rail(
  buf: buffer.Buffer,
  area: Rect,
  strands: List(Strand),
  active: String,
) -> buffer.Buffer {
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.quiet, style.Default)
    |> block.with_title_styled(
      [
        span.span_styled(" AGENTS ", theme.current_bold()),
        span.span_styled(agent_counts(strands), theme.quiet_text()),
      ],
      block.Top,
    )
  buf
  |> buffer.clear(area)
  |> block.render(area, frame)
  |> paragraph.render_text(
    block.inner(area, frame),
    span.text_new(strand_lines(strands, active, None, 0)),
  )
}

/// Renders a centered agent inspector above the main interface.
///
/// ## Examples
///
/// ```gleam
/// let next_buffer = agents.render_overlay(buffer, screen, strands, "main")
/// ```
pub fn render_overlay(
  buf: buffer.Buffer,
  screen: Rect,
  strands: List(Strand),
  active: String,
  selected: Int,
) -> buffer.Buffer {
  let current = theme.overlay_current()
  let quiet = theme.overlay_quiet()
  let signal = theme.overlay_signal()
  let width = int.max(1, int.min(78, screen.size.width - 4))
  let height = int.max(1, int.min(22, screen.size.height - 4))
  let area = geometry.centered_rect(width, height, screen)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.current, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title_styled(
      [
        span.span_styled(" AGENTS ", current),
        span.span_styled("live session topology ", quiet),
      ],
      block.Top,
    )
    |> block.with_padding(1, 1, 2, 2)
  let inside = block.inner(area, frame)
  let footer =
    span.line_new([
      span.span_styled("esc", signal),
      span.span_styled(" close   ↑/↓ select   enter open transcript", quiet),
    ])
  let visible_count = int.max(1, { inside.size.height - 2 } / 3)
  let visible = selection_window(strands, selected, visible_count)
  let lines =
    list.append(strand_lines(visible.0, active, Some(selected), visible.1), [
      span.line_plain(""),
      footer,
    ])
  buf
  |> buffer.clear(area)
  |> block.render(area, frame)
  |> paragraph.render_text(inside, span.text_new(lines))
}

/// Returns a compact summary for narrow-terminal status bars.
///
/// ## Examples
///
/// ```gleam
/// assert agents.summary([]) == "0 live / 0 agents"
/// ```
pub fn summary(strands: List(Strand)) -> String {
  let live =
    list.count(strands, fn(strand) {
      let Strand(live_phase:, ..) = strand
      live_phase != None
    })
  int.to_string(live)
  <> " live / "
  <> int.to_string(list.length(strands))
  <> " agents"
}

fn strand_lines(
  strands: List(Strand),
  active: String,
  selected: Option(Int),
  index_offset: Int,
) -> List(span.Line) {
  strands
  |> list.index_map(fn(strand, index) {
    let Strand(id:, name:, live_phase:) = strand
    let label = case name {
      Some(value) -> text_hygiene.single_line(value)
      None -> text_hygiene.single_line(id)
    }
    let is_active = id == active
    let is_selected = selected == Some(index + index_offset)
    let background = case selected {
      Some(_) -> theme.graphite
      None -> style.Default
    }
    let signal = case selected {
      Some(_) -> theme.overlay_signal()
      None -> theme.signal_bold()
    }
    let current = case selected {
      Some(_) -> theme.overlay_current()
      None -> theme.current_bold()
    }
    let quiet = case selected {
      Some(_) -> theme.overlay_quiet()
      None -> theme.quiet_text()
    }
    let plain = style.new(theme.paper, background, style.none())
    let #(state_mark, state_style, phase) = case live_phase {
      Some(value) -> #("●", current, text_hygiene.single_line(value))
      None -> #("○", quiet, "idle")
    }
    let focus = case is_selected, is_active {
      True, _ -> span.span_styled("▸ ", signal)
      False, True -> span.span_styled("• ", current)
      False, False -> span.span_styled("  ", plain)
    }
    let indent = case string.starts_with(id, "sub:") {
      True -> "  └ "
      False -> ""
    }
    let label_style = case is_selected, is_active {
      True, _ -> signal
      False, True -> current
      False, False -> plain
    }
    [
      span.line_new([
        focus,
        span.span_styled(state_mark <> " ", state_style),
        span.span_styled(indent <> label, label_style),
      ]),
      span.line_new([
        span.span_styled("    ", plain),
        span.span_styled(phase, state_style),
      ]),
      span.line_plain(""),
    ]
  })
  |> list.flatten
}

/// Slices the inspector rows so its absolute selection remains visible.
@internal
pub fn selection_window(
  strands: List(Strand),
  selected: Int,
  visible_count: Int,
) -> #(List(Strand), Int) {
  let count = list.length(strands)
  let max_offset = int.max(0, count - visible_count)
  let centered = int.max(0, selected - { visible_count / 2 })
  let offset = int.min(centered, max_offset)
  #(strands |> list.drop(offset) |> list.take(visible_count), offset)
}

/// Moves the inspector selection and wraps at either edge.
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

/// Returns the stable strand id at one inspector row.
@internal
pub fn selected_strand(strands: List(Strand), selected: Int) -> Option(String) {
  strands
  |> list.drop(selected)
  |> list.first
  |> result.map(fn(strand) {
    let Strand(id:, ..) = strand
    id
  })
  |> option_from_result
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}

fn agent_counts(strands: List(Strand)) -> String {
  "· " <> summary(strands) <> " "
}
