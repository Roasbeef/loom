//// Painting the rail: the column beside the transcript.
////
//// `tui/rail` decides whether the rail is docked and how wide; this module
//// draws it. The column is a separator, a tab bar with a rule under it, a
//// tab's content, and one row of key hints at the bottom. Strands is drawn
//// here, from the same agent lines and the same row renderer
//// (`agent_row.rows`) the strip under the input and the agent workspace use,
//// so a strand looks the same in all three and the rail owns no row layout
//// of its own. Changes is the changes panel, which `tui/render` paints into
//// the rail's content rectangle once this has drawn the frame around it.
////
//// ## Flow
////
//// `render` → `tab_bar` → `strands` → `hint`
////
//// 1. `render` draws the separator down the rail's first column and asks for
////    each part in turn.
//// 2. `tab_bar` names the tabs, marks the open one, and shows how many agents
////    need the operator on Strands, then the rule that closes it.
//// 3. `strands` lists the agents: a heading with their count, then one row
////    each, windowed so the cursor stays on screen when there are more than
////    fit.
//// 4. `hint` says which keys act on the rail right now.
////
//// Nothing here stores state. The cursor is the strip's own focus
//// (`View.strip_focus`): while the rail lists the agents the strip is hidden,
//// so the one cursor and its keys move into the rail, and a person who knows
//// the strip's keys already knows the rail's.

import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/style
import etui/text
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/string
import session_view/agent_roster
import session_view/agent_view
import tui/agent_row
import tui/agent_strip
import tui/layout
import tui/model.{type Model}
import tui/rail
import tui/theme

/// Paints the docked rail into a frame, or nothing when it is not docked.
///
/// ## Examples
///
/// ```gleam
/// let frame = rail_view.render(frame, screen, model)
/// ```
pub fn render(buf: buffer.Buffer, screen: Rect, model: Model) -> buffer.Buffer {
  let area = layout.rail_area(screen, model)
  case area.size.width > 0 {
    False -> buf
    True -> {
      let content = layout.rail_content_area(screen, model)
      let width = area.size.width - 1
      let lines = layout.strip_lines(model)
      let tab = rail.tab(model.view.diff_view)
      buf
      |> separator(area)
      |> paragraph.render_styled(
        geometry.rect_new(area.position.x + 1, area.position.y, width, 2),
        tab_bar(tab, lines, width),
      )
      |> strands(content, model, lines, tab)
      |> hint(area, model, tab)
    }
  }
}

// The rail's left edge, one rule down every row of the rail.
fn separator(buf: buffer.Buffer, area: Rect) -> buffer.Buffer {
  let rule = style.new(theme.divider, style.Default, style.none())
  list.fold(
    int.range(from: 0, to: area.size.height, with: [], run: fn(rows, row) {
      [row, ..rows]
    }),
    buf,
    fn(buf, row) {
      buffer.set_string(
        buf,
        geometry.Position(area.position.x, area.position.y + row),
        "│",
        rule,
      )
    },
  )
}

// The tabs, the open one bold and in the accent colour, and the rule under
// them. Strands carries the number of agents that need the operator, so the
// count is visible while another tab is open.
fn tab_bar(
  tab: rail.Tab,
  lines: List(agent_roster.Line),
  width: Int,
) -> List(span.Line) {
  let needing =
    list.count(lines, fn(line) { agent_view.needs_attention(line.status) })
  let count = case needing {
    0 -> ""
    n -> " ●" <> int.to_string(n)
  }
  let open = theme.current_bold()
  let shut = theme.quiet_text()
  [
    span.line_new([
      span.span_plain(" "),
      span.span_styled("Strands" <> count, case tab {
        rail.Strands -> open
        rail.Changes -> shut
      }),
      span.span_plain("  "),
      span.span_styled("Changes", case tab {
        rail.Changes -> open
        rail.Strands -> shut
      }),
    ]),
    span.line_new([
      span.span_styled(
        string.repeat("─", width),
        style.new(theme.divider, style.Default, style.none()),
      ),
    ]),
  ]
}

// The Strands tab. The Changes tab's content is painted by `tui/render`.
fn strands(
  buf: buffer.Buffer,
  content: Rect,
  model: Model,
  lines: List(agent_roster.Line),
  tab: rail.Tab,
) -> buffer.Buffer {
  case tab {
    rail.Changes -> buf
    rail.Strands -> {
      let heading =
        span.line_new([
          span.span_styled(
            " STRANDS · " <> int.to_string(list.length(lines)),
            theme.quiet_text(),
          ),
        ])

      // One row goes to the heading and, when the agents do not all fit, one
      // to say how many are out of view.
      let room = int.max(0, content.size.height - 1)
      let shown = case list.length(lines) > room {
        True -> agent_strip.window(lines, model.view.strip_focus, room - 1)
        False -> lines
      }
      let rows =
        agent_row.rows(
          shown,
          agent_row.TableRow,
          content.size.width,
          style.Default,
          fn(line) {
            case
              model.view.strip_focus == agent_strip.Browsing(line.id),
              line.id == model.shared.active_strand
            {
              True, _ -> agent_row.Cursor
              False, True -> agent_row.Viewing
              False, False -> agent_row.Unmarked
            }
          },
        )
      let hidden = list.length(lines) - list.length(shown)
      let more = case hidden > 0 {
        True -> [
          span.line_new([
            span.span_styled(
              " +" <> int.to_string(hidden) <> " more · Ctrl+O lists all",
              theme.quiet_text(),
            ),
          ]),
        ]
        False -> []
      }
      paragraph.render_styled(buf, content, [heading, ..list.append(rows, more)])
    }
  }
}

// The keys that act on the rail now: with the cursor in it, the list's keys;
// otherwise how to reach it and how to dock or hide it.
fn hint(
  buf: buffer.Buffer,
  area: Rect,
  model: Model,
  tab: rail.Tab,
) -> buffer.Buffer {
  let words = case tab, model.view.strip_focus {
    rail.Changes, _ -> "Esc closes the changes · Shift+Tab too"
    rail.Strands, agent_strip.Browsing(_) ->
      "↑↓ select · Enter focus · Esc to composer"
    rail.Strands, agent_strip.Composing -> "↓ select an agent · Shift+Tab hides"
  }
  let width = int.max(0, area.size.width - 2)
  paragraph.render_styled(
    buf,
    geometry.rect_new(
      area.position.x + 1,
      area.position.y + area.size.height - 1,
      area.size.width - 1,
      1,
    ),
    [
      span.line_new([
        span.span_styled(
          " " <> text.truncate(words, width, "…"),
          theme.quiet_text(),
        ),
      ]),
    ],
  )
}
