//// Terminal capabilities select a presentation palette at launch.
////
//// Semantic colors stay centralized in theme. A light or reduced-color
//// terminal adapts the completed frame once, before it enters the frame cache;
//// idle views still reuse that exact buffer. Cell content, links, and wide
//// character continuation markers are never reconstructed by this pass.

import etui/buffer
import etui/geometry
import etui/style
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/theme

/// The terminal's rendering capability, separate from conversation state.
@internal
pub type Palette {
  /// The semantic RGB palette is already suitable for a dark terminal.
  Dark

  /// The same semantic roles with contrast against a light background.
  Light

  /// Themeable ANSI colors and the terminal's own background.
  Terminal

  /// Text, weight, and status glyphs with no color escape requirements.
  Plain
}

/// Chooses from the standard terminal environment without I/O in the renderer.
///
/// An absent background hint keeps the established dark palette on truecolor
/// terminals. Reduced-color terminals own their ANSI palette; NO_COLOR keeps
/// the same labels and focus weight without painting fixed backgrounds.
///
/// ## Examples
///
/// ```gleam
/// assert appearance.detect("truecolor", "xterm-256color", "0;15", None) == appearance.Light
/// ```
@internal
pub fn detect(
  color_term: String,
  terminal: String,
  foreground_background: String,
  no_color: Option(String),
) -> Palette {
  case no_color {
    Some(value) if value != "" -> Plain
    Some(_) | None -> {
      let rgb =
        color_term == "truecolor"
        || color_term == "24bit"
        || string.contains(terminal, "direct")
      let background =
        foreground_background
        |> string.split(";")
        |> list.last
        |> result.try(int.parse)
        |> result.unwrap(0)
      case rgb, terminal, background {
        _, "dumb", _ -> Plain
        False, _, _ -> Terminal
        True, _, 7 | True, _, 15 -> Light
        True, _, _ -> Dark
      }
    }
  }
}

/// Adapts a completed frame while preserving its characters and metadata.
///
/// The common dark path returns its input directly; there is no per-cell work
/// or new buffer identity on an idle repaint.
///
/// ## Examples
///
/// ```gleam
/// // appearance.apply(frame, appearance.Light)
/// ```
@internal
pub fn apply(frame: buffer.Buffer, palette: Palette) -> buffer.Buffer {
  case palette {
    Dark -> frame
    Light | Terminal | Plain -> {
      let area = buffer.area(frame)
      cells(frame, palette, area, 0, area.size.width * area.size.height)
    }
  }
}

// One row-major pass retains wide cells exactly as etui created them.
fn cells(
  frame: buffer.Buffer,
  palette: Palette,
  area: geometry.Rect,
  index: Int,
  size: Int,
) -> buffer.Buffer {
  case index >= size {
    True -> frame
    False -> {
      let position =
        geometry.Position(
          area.position.x + index % area.size.width,
          area.position.y + index / area.size.width,
        )
      let cell = buffer.get_cell(frame, position)
      let colors = cell.style
      let remapped =
        style.Style(
          ..colors,
          fg: foreground(colors.fg, palette),
          bg: background(colors.bg, palette),
          underline_color: foreground(colors.underline_color, palette),
        )
      let frame = case remapped == colors {
        True -> frame
        False ->
          buffer.set_cell(frame, position, buffer.Cell(..cell, style: remapped))
      }
      cells(frame, palette, area, index + 1, size)
    }
  }
}

fn foreground(color: style.Color, palette: Palette) -> style.Color {
  case palette {
    Dark -> color
    Plain -> style.Default
    Light ->
      case color {
        value if value == theme.divider -> style.Rgb(162, 177, 194)
        value if value == theme.paper -> style.Rgb(32, 43, 60)
        value if value == theme.quiet || value == theme.muted ->
          style.Rgb(78, 93, 111)
        value if value == theme.current -> style.Rgb(0, 104, 125)
        value if value == theme.signal -> style.Rgb(137, 77, 0)
        value if value == theme.advisor -> style.Rgb(106, 64, 161)
        value if value == theme.danger -> style.Rgb(178, 35, 59)
        value if value == theme.added -> style.Rgb(35, 111, 58)
        other -> other
      }
    Terminal ->
      case color {
        value if value == theme.current -> style.Indexed(6)
        value if value == theme.signal -> style.Indexed(3)
        value if value == theme.advisor -> style.Indexed(5)
        value if value == theme.danger -> style.Indexed(1)
        value if value == theme.added -> style.Indexed(2)
        style.Rgb(..) -> style.Default
        other -> other
      }
  }
}

fn background(color: style.Color, palette: Palette) -> style.Color {
  case palette {
    Dark -> color
    Plain | Terminal -> style.Default
    Light ->
      case color {
        value if value == theme.graphite -> style.Rgb(243, 245, 248)
        value if value == theme.raised -> style.Rgb(220, 231, 243)
        value if value == theme.user_background -> style.Rgb(251, 241, 221)
        value if value == theme.assistant_background -> style.Rgb(228, 242, 243)
        value if value == theme.added_bg -> style.Rgb(224, 242, 228)
        value if value == theme.removed_bg -> style.Rgb(249, 228, 232)
        other -> other
      }
  }
}
