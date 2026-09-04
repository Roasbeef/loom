//// Repeatable microbenchmarks for the terminal rendering hot paths.
////
//// This module stays in `dev/` so neither its runner nor `gleamy_bench` enters
//// the shipped client. The panel pair mirrors the two large bordered regions
//// in a normal frame and isolates the cell-by-cell interior clear removed by
//// `tui.render_panel_border`.

import etui/buffer
import etui/geometry.{type Rect}
import etui/style
import etui/widgets/block
import gleam/io
import gleamy/bench
import tui
import tui/theme

type PanelPair {
  PanelPair(base: buffer.Buffer, transcript: Rect, input: Rect)
}

/// Measures the panel-rendering work removed from each terminal frame.
///
/// Run this benchmark more than once and compare the same runtime, machine,
/// and commit. The reported durations are milliseconds per invocation.
///
/// ## Examples
///
/// ```sh
/// make bench-tui
/// ```
pub fn main() {
  bench.run(
    [
      bench.Input(
        "80x24",
        panel_pair(80, 24, transcript_width: 80, transcript_height: 17),
      ),
      bench.Input(
        "200x50",
        panel_pair(200, 50, transcript_width: 166, transcript_height: 43),
      ),
    ],
    [
      bench.Function("etui block", render_etui_panels),
      bench.Function("loom border", render_loom_panels),
    ],
    [bench.Warmup(250), bench.Duration(1500), bench.Decimals(4)],
  )
  |> bench.table([bench.IPS, bench.Min, bench.Mean, bench.P(99)])
  |> io.println()
}

fn panel_pair(
  width: Int,
  height: Int,
  transcript_width transcript_width: Int,
  transcript_height transcript_height: Int,
) -> PanelPair {
  let screen = geometry.rect_new(0, 0, width, height)
  let canvas =
    buffer.buffer_new_filled(
      screen,
      " ",
      style.new(style.Default, style.Default, style.dim()),
    )
  PanelPair(
    base: canvas,
    transcript: geometry.rect_new(0, 1, transcript_width, transcript_height),
    input: geometry.rect_new(0, height - 6, width, 4),
  )
}

fn render_etui_panels(pair: PanelPair) -> buffer.Buffer {
  let transcript =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.quiet, style.Default)
    |> block.with_title(" transcript / main ", block.Top)
  let input =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, style.Default)
    |> block.with_title(" message ", block.Top)

  pair.base
  |> block.render(pair.transcript, transcript)
  |> block.render(pair.input, input)
}

fn render_loom_panels(pair: PanelPair) -> buffer.Buffer {
  pair.base
  |> tui.render_panel_border(
    pair.transcript,
    " transcript / main ",
    theme.quiet,
  )
  |> tui.render_panel_border(pair.input, " message ", theme.signal)
}
