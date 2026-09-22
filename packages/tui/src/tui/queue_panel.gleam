//// The queued-input inspector presents captured scheduling facts without
//// claiming that a bounded queue excerpt is the complete submitted message.
//// Selection owns a stable opaque identity, while paging owns only the
//// selected excerpt. Enter remains the sole path into the authoritative,
//// revision-fenced editor managed by `queue_editor`.

import etui/geometry
import etui/span
import etui/style
import etui/text
import gleam/int
import gleam/list
import gleam/string
import tui/snapshot_view
import tui/text_hygiene
import tui/theme

type RowFocus {
  Selected
  Ordinary
}

/// Renders the bounded queue list and selected captured excerpt.
///
/// ## Examples
///
/// ```gleam
/// // queue_panel.lines(rows, 0, 0, area)
/// ```
@internal
pub fn lines(
  rows: List(snapshot_view.PendingInput),
  selected: Int,
  preview_scroll: Int,
  area: geometry.Rect,
) -> List(span.Line) {
  case selected_row(rows, selected) {
    Error(Nil) -> [
      styled_line(
        "No queued inputs in the current captured view",
        area.size.width,
        theme.overlay_quiet(),
      ),
    ]
    Ok(row) -> {
      let preview_scroll =
        int.min(preview_scroll, max_scroll(rows, selected, area))
      case wide(area) {
        True -> wide_lines(rows, row, selected, preview_scroll, area)
        False ->
          compact_lines(row, selected, list.length(rows), preview_scroll, area)
      }
    }
  }
}

/// Returns the exact number of excerpt rows advanced by one page key.
///
/// ## Examples
///
/// ```gleam
/// // queue_panel.page_rows(area)
/// ```
@internal
pub fn page_rows(area: geometry.Rect) -> Int {
  int.max(1, area.size.height - 2)
}

/// Clamps paging to the selected excerpt's wrapped terminal geometry.
///
/// ## Examples
///
/// ```gleam
/// // queue_panel.max_scroll(rows, 0, area)
/// ```
@internal
pub fn max_scroll(
  rows: List(snapshot_view.PendingInput),
  selected: Int,
  area: geometry.Rect,
) -> Int {
  case selected_row(rows, selected) {
    Error(Nil) -> 0
    Ok(row) ->
      int.max(
        0,
        list.length(wrapped_excerpt(row.text, preview_width(area)))
          - page_rows(area),
      )
  }
}

fn wide(area: geometry.Rect) -> Bool {
  area.size.width >= 70 && area.size.height >= 6
}

fn wide_lines(
  rows: List(snapshot_view.PendingInput),
  current: snapshot_view.PendingInput,
  selected: Int,
  preview_scroll: Int,
  area: geometry.Rect,
) -> List(span.Line) {
  let left_width = int.min(36, { area.size.width * 2 } / 5)
  let gap = 2
  let right_width = int.max(1, area.size.width - left_width - gap)
  let left = queue_rows(rows, selected, left_width, area.size.height)
  let right =
    preview_rows(current, preview_scroll, right_width, area.size.height)
  let height = int.max(list.length(left), list.length(right))
  int.range(0, height, [], fn(output, index) {
    let left_line = line_at(left, index, left_width)
    let right_line = line_at(right, index, right_width)
    [
      span.line_new(
        list.append(left_line.spans, [
          span.span_styled("  ", theme.overlay_plain()),
          ..right_line.spans
        ]),
      ),
      ..output
    ]
  })
  |> list.reverse
}

fn compact_lines(
  row: snapshot_view.PendingInput,
  selected: Int,
  count: Int,
  preview_scroll: Int,
  area: geometry.Rect,
) -> List(span.Line) {
  let width = area.size.width
  [
    selected_line(row, width, selected, count),
    preview_heading(row, width),
    ..excerpt_rows(row, preview_scroll, width, page_rows(area))
  ]
}

fn queue_rows(
  rows: List(snapshot_view.PendingInput),
  selected: Int,
  width: Int,
  height: Int,
) -> List(span.Line) {
  let visible = int.max(1, height - 1)
  let offset = int.min(selected, int.max(0, list.length(rows) - visible))
  [
    styled_line("CAPTURED QUEUE", width, theme.overlay_current()),
    ..list.index_map(
      rows |> list.drop(offset) |> list.take(visible),
      fn(row, index) {
        queue_line(
          row,
          case offset + index == selected {
            True -> Selected
            False -> Ordinary
          },
          width,
        )
      },
    )
  ]
}

fn preview_rows(
  row: snapshot_view.PendingInput,
  preview_scroll: Int,
  width: Int,
  height: Int,
) -> List(span.Line) {
  [
    styled_line("SELECTED MESSAGE", width, theme.overlay_current()),
    preview_heading(row, width),
    ..excerpt_rows(row, preview_scroll, width, int.max(1, height - 2))
  ]
}

fn selected_line(
  row: snapshot_view.PendingInput,
  width: Int,
  selected: Int,
  count: Int,
) -> span.Line {
  let label =
    "▸ "
    <> badges(row)
    <> " "
    <> text_hygiene.single_line(row.id)
    <> " · item "
    <> int.to_string(selected + 1)
    <> "/"
    <> int.to_string(count)
  raised_line(label, width, kind_color(row.kind))
}

fn queue_line(
  row: snapshot_view.PendingInput,
  focus: RowFocus,
  width: Int,
) -> span.Line {
  let marker = case focus {
    Selected -> "▸ "
    Ordinary -> "  "
  }
  let label = marker <> badges(row) <> " " <> text_hygiene.single_line(row.id)
  case focus {
    Selected -> raised_line(label, width, kind_color(row.kind))
    Ordinary -> styled_line(label, width, theme.overlay_plain())
  }
}

fn badges(row: snapshot_view.PendingInput) -> String {
  let kind = case row.kind {
    snapshot_view.Queue -> "[QUEUE]"
    snapshot_view.Steer -> "[STEER]"
  }
  let access = case row.editing {
    snapshot_view.Editable -> "[EDIT]"
    snapshot_view.ReadOnly -> "[READ-ONLY]"
  }
  kind <> " " <> access
}

fn preview_heading(row: snapshot_view.PendingInput, width: Int) -> span.Line {
  styled_line(
    "Captured excerpt · revision "
      <> int.to_string(row.revision)
      <> case row.editing {
      snapshot_view.Editable -> " · Enter fetches full text"
      snapshot_view.ReadOnly -> " · full text unavailable"
    },
    width,
    theme.overlay_quiet(),
  )
}

fn excerpt_rows(
  row: snapshot_view.PendingInput,
  preview_scroll: Int,
  width: Int,
  height: Int,
) -> List(span.Line) {
  row.text
  |> wrapped_excerpt(width)
  |> list.drop(preview_scroll)
  |> list.take(height)
  |> list.map(fn(line) { raised_line(line, width, theme.paper) })
}

fn wrapped_excerpt(value: String, width: Int) -> List(String) {
  value
  |> text_hygiene.multiline
  |> string.split("\n")
  |> list.flat_map(fn(line) { text.wrap(line, int.max(1, width)) })
}

fn preview_width(area: geometry.Rect) -> Int {
  case wide(area) {
    True ->
      int.max(1, area.size.width - int.min(36, { area.size.width * 2 } / 5) - 2)
    False -> int.max(1, area.size.width)
  }
}

fn selected_row(
  rows: List(snapshot_view.PendingInput),
  selected: Int,
) -> Result(snapshot_view.PendingInput, Nil) {
  rows |> list.drop(selected) |> list.first
}

fn kind_color(kind: snapshot_view.InputKind) -> style.Color {
  case kind {
    snapshot_view.Queue -> theme.current
    snapshot_view.Steer -> theme.signal
  }
}

fn raised_line(
  value: String,
  width: Int,
  foreground: style.Color,
) -> span.Line {
  styled_line(value, width, style.new(foreground, theme.raised, style.none()))
}

fn styled_line(
  value: String,
  width: Int,
  appearance: style.Style,
) -> span.Line {
  let visible =
    value
    |> text_hygiene.single_line
    |> text.truncate(width, "…")
    |> text.pad_right(width)
  span.line_new([span.span_styled(visible, appearance)])
}

fn line_at(lines: List(span.Line), index: Int, width: Int) -> span.Line {
  case list.first(list.drop(lines, index)) {
    Ok(line) -> line
    Error(Nil) -> styled_line("", width, theme.overlay_plain())
  }
}
