//// Padding must preserve the existing styled-cell output, including clipping,
//// links, Unicode continuation cells and the alignment of colored rows.
//// The reference is the previous padded-paragraph renderer, fed the same rows
//// as a complete frame. Comparing cells rather than text catches lost styles
//// and wide-cell boundaries that a plain snapshot cannot distinguish.

import etui/buffer
import etui/geometry
import etui/span
import etui/style
import etui/text
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import tui
import tui/connection
import tui/layout
import tui/model
import tui/render
import tui/theme
import tui/workspace

pub fn direct_padding_preserves_styled_cells_test() {
  let speaker = style.new(theme.paper, theme.raised, style.bold())
  let other = style.new(theme.quiet, theme.user_background, style.italic())
  let rows = [
    span.line_new([
      span.span_styled("👩‍💻 é 中文", speaker)
        |> span.with_link("https://example.test/row"),
      span.span_styled(" suffix", other),
    ]),
    span.line_aligned([span.span_styled("short", speaker)], text.Center),
    span.line_aligned([span.span_styled("短", other)], text.Right),
    span.line_new([span.span_styled("", speaker)]),
    span.line_new([span.span_styled("界界界界界", speaker)]),
    span.line_plain("plain"),
    span.line_new([]),
    span.line_new([span.span_styled(string.repeat("x", 100) <> "界", speaker)]),
  ]
  list.each([4, 9, 40, 100], fn(width) { compare_rows(rows, width) })
}

fn compare_rows(rows: List(span.Line), width: Int) {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("padding", None),
      fn() { 0 },
    )
  let count = list.length(rows)
  let base =
    model.Model(
      ..base,
      view: model.View(
        ..base.view,
        width:,
        height: 30,
        rendered_row_count: count,
        revealed_rows: count,
        caches: model.Caches(
          ..base.view.caches,
          rendered_rows: list.reverse(rows),
        ),
      ),
    )
  let screen = geometry.rect_new(0, 0, width, 30)
  let #(_, body, _, _) = layout.layout(screen, base)
  let #(conversation, _) = layout.queue_body_layout(body, base)
  let #(panel, _, _) = layout.body_layout(conversation, base)
  let area = layout.transcript_inner(panel)
  let alternate =
    model.Model(..base, view: model.View(..base.view, repaint_phase: True))
  list.each([base, alternate], fn(base) {
    let blank =
      model.Model(
        ..base,
        view: model.View(
          ..base.view,
          caches: model.Caches(..base.view.caches, rendered_rows: []),
        ),
      )
    let #(canvas, _) = render.render_frame(blank, screen)
    let #(actual, _) = render.render_frame(base, screen)
    let expected =
      paragraph.render_styled(
        canvas,
        area,
        list.map(rows, padded(_, area.size.width)),
      )
    int.range(0, area.size.height, Nil, fn(_, y) {
      int.range(0, area.size.width, Nil, fn(_, x) {
        let at = geometry.Position(area.position.x + x, area.position.y + y)
        assert buffer.get_cell(actual, at) == buffer.get_cell(expected, at)
      })
    })
  })
}

// This is the previous rendering path, retained only as a cell-level oracle.
fn padded(line: span.Line, width: Int) -> span.Line {
  case line.spans {
    [first, ..]
      if first.style.bg == theme.user_background
      || first.style.bg == theme.raised
    ->
      span.Line(
        ..line,
        spans: list.append(line.spans, [
          span.span_styled(
            string.repeat(" ", int.max(0, width - span.line_width(line))),
            first.style,
          ),
        ]),
      )
    _ -> line
  }
}
