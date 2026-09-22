//// Notes use one stable-key browser in the transcript and agent inspector.
////
//// The caller owns note provenance and Markdown/JSON interpretation. This
//// module owns only selection, bounded layout, focus styling, and body paging,
//// so neither surface can accidentally borrow transcript reading state.

import etui/geometry.{type Rect}
import etui/span
import etui/style
import etui/text
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/text_hygiene
import tui/theme

/// Notes switch only their selected body's representation.
@internal
pub type Mode {
  /// Human-readable structured prose.
  Readable

  /// Exact complete JSON/text captured by the notes read.
  Raw
}

/// One note prepared by the owning TUI model.
@internal
pub type Row {
  Row(
    /// Durable note key.
    key: String,
    /// Revision which last wrote this value.
    seq: Int,
    /// Sanitized one-line list summary.
    excerpt: String,
    /// Whether the retained value is complete or excerpted.
    extent: String,
    /// Relation between the write and current turn.
    relation: String,
    /// Prepared body for the selected representation.
    body: List(span.Line),
  )
}

/// Resolves a stable key, falling back to the first retained row.
///
/// ## Examples
///
/// ```gleam
/// // note_panel.selected(rows, Some("plan"))
/// ```
@internal
pub fn selected(rows: List(Row), wanted: Option(String)) -> Option(Row) {
  case wanted {
    Some(key) ->
      case list.find(rows, fn(row) { row.key == key }) {
        Ok(row) -> Some(row)
        Error(Nil) -> first(rows)
      }
    None -> first(rows)
  }
}

/// Moves between retained keys without changing any transcript position.
///
/// ## Examples
///
/// ```gleam
/// // note_panel.move(rows, Some("plan"), 1)
/// ```
@internal
pub fn move(
  rows: List(Row),
  wanted: Option(String),
  amount: Int,
) -> Option(String) {
  case selected(rows, wanted) {
    None -> None
    Some(current) -> {
      let index =
        rows
        |> list.index_map(fn(row, index) { #(row.key, index) })
        |> list.key_find(current.key)
        |> result.unwrap(0)
      let next = int.clamp(index + amount, 0, int.max(0, list.length(rows) - 1))
      rows
      |> list.drop(next)
      |> list.first
      |> result.map(fn(row) { row.key })
      |> option_from_result
    }
  }
}

/// Returns the exact number of selected-body rows visible in this geometry.
///
/// ## Examples
///
/// ```gleam
/// // note_panel.page_step(area)
/// ```
@internal
pub fn page_step(area: Rect) -> Int {
  case area.size.width >= 72 && area.size.height >= 8 {
    True -> int.max(1, area.size.height - 4)
    False if area.size.height <= 2 -> int.max(1, area.size.height)
    False -> int.max(1, area.size.height - 2)
  }
}

/// Returns the width used to prepare the selected note body.
///
/// ## Examples
///
/// ```gleam
/// // note_panel.body_width(area)
/// ```
@internal
pub fn body_width(area: Rect) -> Int {
  case area.size.width >= 72 && area.size.height >= 8 {
    True ->
      int.max(1, area.size.width - int.min(38, { area.size.width * 2 } / 5) - 2)
    False -> int.max(1, area.size.width)
  }
}

/// Returns the greatest body offset which still displays content.
///
/// ## Examples
///
/// ```gleam
/// // note_panel.max_scroll(rows, Some("plan"))
/// ```
@internal
pub fn max_scroll(rows: List(Row), wanted: Option(String)) -> Int {
  case selected(rows, wanted) {
    Some(row) -> int.max(0, list.length(row.body) - 1)
    None -> 0
  }
}

/// Renders the same note browser into either owning surface.
///
/// ## Examples
///
/// ```gleam
/// // note_panel.render(rows, Some("plan"), 0, context, area)
/// ```
@internal
pub fn render(
  rows: List(Row),
  wanted: Option(String),
  scroll: Int,
  context: List(String),
  area: Rect,
) -> span.Text {
  let lines = case selected(rows, wanted) {
    None -> list.map(context, styled(_, area.size.width, theme.overlay_quiet()))
    Some(current) ->
      case area.size.width >= 72 && area.size.height >= 8 {
        True -> wide(rows, current, scroll, context, area)
        False -> compact(current, scroll, context, area)
      }
  }
  span.text_new(lines)
}

fn compact(
  current: Row,
  scroll: Int,
  context: List(String),
  area: Rect,
) -> List(span.Line) {
  let body_rows = page_step(area)
  case area.size.height <= 2 {
    True ->
      body_slice(current.body, scroll, body_rows)
      |> shade(area.size.width)
    False -> {
      let heading =
        styled(
          "▸ " <> current.key <> " · " <> current.extent,
          area.size.width,
          theme.overlay_signal(),
        )
      let body =
        body_slice(current.body, scroll, body_rows)
        |> shade(area.size.width)
      case area.size.height >= 3, list.last(context) {
        True, Ok(value) -> [
          styled(value, area.size.width, theme.overlay_quiet()),
          heading,
          ..body
        ]
        _, _ -> [heading, ..body]
      }
    }
  }
}

fn wide(
  rows: List(Row),
  current: Row,
  scroll: Int,
  context: List(String),
  area: Rect,
) -> List(span.Line) {
  let left_width = int.min(38, { area.size.width * 2 } / 5)
  let right_width = int.max(1, area.size.width - left_width - 2)
  let visible = int.max(1, { area.size.height - list.length(context) } / 3)
  let list_rows = note_rows(rows, current, left_width, visible, context)
  let body_rows = [
    styled(
      current.key <> " · " <> current.extent,
      right_width,
      theme.overlay_current(),
    ),
    styled(
      "updated at revision "
        <> int.to_string(current.seq)
        <> " · "
        <> string.lowercase(current.extent)
        <> current.relation,
      right_width,
      theme.overlay_quiet(),
    ),
    ..body_slice(current.body, scroll, page_step(area))
    |> shade(right_width)
  ]
  combine(list_rows, body_rows, left_width, right_width)
}

fn body_slice(
  body: List(span.Line),
  scroll: Int,
  count: Int,
) -> List(span.Line) {
  let offset = int.min(int.max(0, scroll), int.max(0, list.length(body) - 1))
  body |> list.drop(offset) |> list.take(count)
}

fn note_rows(
  rows: List(Row),
  current: Row,
  width: Int,
  visible: Int,
  context: List(String),
) -> List(span.Line) {
  let index =
    rows
    |> list.index_map(fn(row, index) { #(row.key, index) })
    |> list.key_find(current.key)
    |> result.unwrap(0)
  let offset = int.min(index, int.max(0, list.length(rows) - visible))
  let heading = context |> list.map(styled(_, width, theme.overlay_quiet()))
  list.append(
    heading,
    rows
      |> list.drop(offset)
      |> list.take(visible)
      |> list.flat_map(fn(row) {
        let focus = row.key == current.key
        let background = case focus {
          True -> theme.raised
          False -> theme.graphite
        }
        let marker = case focus {
          True -> "▸ "
          False -> "  "
        }
        let primary = style.new(theme.paper, background, style.none())
        let quiet = style.new(theme.quiet, background, style.none())
        [
          styled(marker <> row.key, width, primary),
          styled(
            "  r" <> int.to_string(row.seq) <> " · " <> row.extent,
            width,
            quiet,
          ),
          styled("  " <> row.excerpt, width, quiet),
        ]
      }),
  )
}

fn shade(lines: List(span.Line), width: Int) -> List(span.Line) {
  list.map(lines, fn(line) {
    let spans =
      list.map(line.spans, fn(value) {
        let style.Style(fg:, modifier:, sub_modifier:, underline_color:, ..) =
          value.style
        span.Span(
          ..value,
          style: style.Style(
            fg:,
            bg: theme.raised,
            modifier:,
            sub_modifier:,
            underline_color:,
          ),
        )
      })
    let used = span.line_width(span.line_new(spans))
    let appearance = style.new(theme.paper, theme.raised, style.none())
    span.line_new(
      list.append(spans, [
        span.span_styled(
          text.pad_right("", int.max(0, width - used)),
          appearance,
        ),
      ]),
    )
  })
}

fn combine(
  left: List(span.Line),
  right: List(span.Line),
  left_width: Int,
  right_width: Int,
) -> List(span.Line) {
  let height = int.max(list.length(left), list.length(right))
  int.range(0, height, [], fn(lines, index) {
    let left = line_at(left, index, left_width)
    let right = line_at(right, index, right_width)
    [
      span.line_new(
        list.append(left.spans, [
          span.span_styled("  ", theme.overlay_plain()),
          ..right.spans
        ]),
      ),
      ..lines
    ]
  })
  |> list.reverse
}

fn styled(value: String, width: Int, appearance: style.Style) -> span.Line {
  span.line_new([
    span.span_styled(
      value
        |> text_hygiene.single_line
        |> text.truncate(int.max(0, width), "…")
        |> text.pad_right(int.max(0, width)),
      appearance,
    ),
  ])
}

fn line_at(lines: List(span.Line), index: Int, width: Int) -> span.Line {
  lines
  |> list.drop(index)
  |> list.first
  |> result.lazy_unwrap(fn() { styled("", width, theme.overlay_plain()) })
}

fn first(rows: List(a)) -> Option(a) {
  rows |> list.first |> option_from_result
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(Nil) -> None
  }
}
