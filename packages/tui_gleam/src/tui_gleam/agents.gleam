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
import gleam/option.{None, Some}
import gleam/string
import tui_gleam/protocol.{type Strand, Strand}
import tui_gleam/text_hygiene
import tui_gleam/theme

/// Renders the always-visible agent rail on wide terminals.
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
  |> block.render(area, frame)
  |> paragraph.render_text(
    block.inner(area, frame),
    span.text_new(strand_lines(strands, active)),
  )
}

/// Renders a centered agent inspector above the main interface.
pub fn render_overlay(
  buf: buffer.Buffer,
  screen: Rect,
  strands: List(Strand),
  active: String,
) -> buffer.Buffer {
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
        span.span_styled(" AGENTS ", theme.current_bold()),
        span.span_styled("live session topology ", theme.quiet_text()),
      ],
      block.Top,
    )
    |> block.with_padding(1, 1, 2, 2)
  let inside = block.inner(area, frame)
  let footer =
    span.line_new([
      span.span_styled("esc", theme.signal_bold()),
      span.span_styled(
        " close   /strand <name> switches focus",
        theme.quiet_text(),
      ),
    ])
  let lines =
    list.append(strand_lines(strands, active), [
      span.line_plain(""),
      footer,
    ])
  buf
  |> block.render(area, frame)
  |> paragraph.render_text(inside, span.text_new(lines))
}

/// Returns a compact summary for narrow-terminal status bars.
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

fn strand_lines(strands: List(Strand), active: String) -> List(span.Line) {
  list.flat_map(strands, fn(strand) {
    let Strand(id:, name:, live_phase:) = strand
    let label = case name {
      Some(value) -> text_hygiene.single_line(value)
      None -> text_hygiene.single_line(id)
    }
    let is_active = id == active
    let #(state_mark, state_style, phase) = case live_phase {
      Some(value) -> #(
        "●",
        theme.current_bold(),
        text_hygiene.single_line(value),
      )
      None -> #("○", theme.quiet_text(), "idle")
    }
    let focus = case is_active {
      True -> span.span_styled("▸ ", theme.signal_bold())
      False -> span.span_plain("  ")
    }
    let indent = case string.starts_with(id, "sub:") {
      True -> "  └ "
      False -> ""
    }
    let label_style = case is_active {
      True -> theme.signal_bold()
      False -> style.new(theme.paper, style.Default, style.none())
    }
    [
      span.line_new([
        focus,
        span.span_styled(state_mark <> " ", state_style),
        span.span_styled(indent <> label, label_style),
      ]),
      span.line_new([
        span.span_plain("    "),
        span.span_styled(phase, state_style),
      ]),
      span.line_plain(""),
    ]
  })
}

fn agent_counts(strands: List(Strand)) -> String {
  "· " <> summary(strands) <> " "
}
