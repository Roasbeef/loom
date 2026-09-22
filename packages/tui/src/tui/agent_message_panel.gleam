//// The message inspector presents observed sends without inventing delivery.
////
//// Selection follows the durable entry and provider-call pair rather than a
//// row index. Newer captures can therefore arrive above the selected send
//// without moving inspection to another message. The projection remains the
//// authority for provenance, retention, and exact observed state.

import etui/geometry.{type Rect}
import etui/span
import etui/style
import etui/text
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/agent_messages
import tui/text_hygiene
import tui/theme

type RowFocus {
  SelectedRow
  OrdinaryRow
}

/// Identifies one send across capture refreshes.
///
/// ## Examples
///
/// ```gleam
/// // agent_message_panel.identity(item)
/// ```
@internal
pub fn identity(item: agent_messages.Item) -> String {
  item.source <> "\u{0}" <> item.entry_id <> "\u{0}" <> item.call_id
}

/// Resolves the retained selection, falling back to the newest visible send.
///
/// ## Examples
///
/// ```gleam
/// // agent_message_panel.selected(items, None)
/// ```
@internal
pub fn selected(
  messages: List(agent_messages.Item),
  wanted: Option(String),
) -> Option(agent_messages.Item) {
  case wanted {
    Some(key) ->
      case list.find(messages, fn(item) { identity(item) == key }) {
        Ok(item) -> Some(item)
        Error(Nil) -> first(messages)
      }
    None -> first(messages)
  }
}

/// Moves the selected send by one row, wrapping at the retained edges.
///
/// ## Examples
///
/// ```gleam
/// // agent_message_panel.move(items, None, 1)
/// ```
@internal
pub fn move(
  messages: List(agent_messages.Item),
  wanted: Option(String),
  amount: Int,
) -> Option(String) {
  case selected(messages, wanted) {
    None -> None
    Some(current) -> {
      let index =
        messages
        |> list.index_map(fn(item, index) { #(identity(item), index) })
        |> list.key_find(identity(current))
        |> result.unwrap(0)
      let count = list.length(messages)
      let next = case index + amount {
        candidate if candidate < 0 -> count - 1
        candidate if candidate >= count -> 0
        candidate -> candidate
      }
      messages
      |> list.drop(next)
      |> list.first
      |> result.map(identity)
      |> option_from_result
    }
  }
}

/// Renders a bounded send list and independently scrollable body preview.
///
/// ## Examples
///
/// ```gleam
/// // agent_message_panel.render(items, None, 0, area)
/// ```
@internal
pub fn render(
  messages: List(agent_messages.Item),
  wanted: Option(String),
  body_scroll: Int,
  area: Rect,
) -> span.Text {
  let lines = case selected(messages, wanted) {
    None -> empty(area.size.width)
    Some(current) ->
      case area.size.width >= 72 && area.size.height >= 8 {
        True -> wide(messages, current, body_scroll, area)
        False -> stacked(messages, current, body_scroll, area)
      }
  }
  span.text_new(lines)
}

/// Returns the exact number of body rows displayed by this panel geometry.
///
/// ## Examples
///
/// ```gleam
/// // agent_message_panel.page_step(area)
/// ```
@internal
pub fn page_step(area: Rect) -> Int {
  case area.size.width >= 72 && area.size.height >= 8 {
    True -> int.max(1, area.size.height - 5)
    False if area.size.height <= 2 -> int.max(1, area.size.height)
    False -> int.max(1, area.size.height - 2)
  }
}

fn empty(width: Int) -> List(span.Line) {
  [
    styled("MESSAGES", width, theme.overlay_current()),
    styled(
      "No sends observed for this agent in the latest 20 retained sends.",
      width,
      theme.overlay_plain(),
    ),
    styled(
      "Older or unloaded history may be absent.",
      width,
      theme.overlay_quiet(),
    ),
  ]
}

fn stacked(
  messages: List(agent_messages.Item),
  current: agent_messages.Item,
  body_scroll: Int,
  area: Rect,
) -> List(span.Line) {
  let width = area.size.width
  let body_rows = page_step(area)
  use <- bool.lazy_guard(area.size.height <= 2, fn() {
    compact_body(current, body_scroll, width, body_rows)
  })
  let selected_row = compact_message_row(current, width, SelectedRow)
  let remaining =
    messages
    |> list.filter(fn(item) { identity(item) != identity(current) })
    |> list.take(2)
    |> list.flat_map(fn(item) { compact_message_row(item, width, OrdinaryRow) })
  list.append(
    selected_row,
    list.append(
      compact_preview(current, body_scroll, width, body_rows),
      remaining,
    ),
  )
}

fn compact_body(
  item: agent_messages.Item,
  body_scroll: Int,
  width: Int,
  body_rows: Int,
) -> List(span.Line) {
  item.body
  |> text_hygiene.multiline
  |> string.split("\n")
  |> list.flat_map(fn(line) { text.wrap(line, int.max(1, width - 1)) })
  |> list.drop(body_scroll)
  |> list.take(body_rows)
  |> list.map(fn(line) {
    styled(
      " " <> line,
      width,
      style.new(theme.paper, theme.raised, style.none()),
    )
  })
}

fn compact_message_row(
  item: agent_messages.Item,
  width: Int,
  focus: RowFocus,
) -> List(span.Line) {
  let background = case focus {
    SelectedRow -> theme.raised
    OrdinaryRow -> theme.graphite
  }
  let marker = case focus {
    SelectedRow -> "▸ "
    OrdinaryRow -> "  "
  }
  [
    styled(
      marker
        <> item.source
        <> " → "
        <> item.target
        <> " · "
        <> state_label(item.state)
        <> " · "
        <> one_line_excerpt(item.body),
      width,
      style.new(state_color(item.state), background, style.none()),
    ),
  ]
}

fn compact_preview(
  item: agent_messages.Item,
  body_scroll: Int,
  width: Int,
  body_rows: Int,
) -> List(span.Line) {
  let body =
    item.body
    |> text_hygiene.multiline
    |> string.split("\n")
    |> list.flat_map(fn(line) { text.wrap(line, int.max(1, width - 1)) })
  let offset =
    int.min(int.max(0, body_scroll), int.max(0, list.length(body) - 1))
  let extent = case item.body_extent {
    agent_messages.Complete -> "complete"
    agent_messages.Excerpt -> "retained excerpt"
  }
  let shade = style.new(theme.paper, theme.graphite, style.none())
  [
    styled(" " <> extent <> " · r" <> int.to_string(item.seq), width, shade),
    ..list.map(list.take(list.drop(body, offset), body_rows), fn(line) {
      styled(" " <> line, width, shade)
    })
  ]
}

fn wide(
  messages: List(agent_messages.Item),
  current: agent_messages.Item,
  body_scroll: Int,
  area: Rect,
) -> List(span.Line) {
  let width = area.size.width
  let left_width = int.min(38, { width * 2 } / 5)
  let gap = 2
  let right_width = int.max(1, width - left_width - gap)
  let visible = int.max(1, { area.size.height - 2 } / 3)
  let left = message_rows(messages, current, left_width, visible)
  let right = preview(current, body_scroll, right_width, page_step(area))
  let height = int.max(list.length(left), list.length(right))
  int.range(0, height, [], fn(lines, index) {
    let left_line = line_at(left, index, left_width)
    let right_line = line_at(right, index, right_width)
    [
      span.line_new(
        list.append(left_line.spans, [
          span.span_styled("  ", theme.overlay_plain()),
          ..right_line.spans
        ]),
      ),
      ..lines
    ]
  })
  |> list.reverse
}

fn message_rows(
  messages: List(agent_messages.Item),
  current: agent_messages.Item,
  width: Int,
  visible: Int,
) -> List(span.Line) {
  let selected_index =
    messages
    |> list.index_map(fn(item, index) { #(identity(item), index) })
    |> list.key_find(identity(current))
    |> result.unwrap(0)
  let offset =
    int.min(selected_index, int.max(0, list.length(messages) - visible))
  let visible_messages = messages |> list.drop(offset) |> list.take(visible)
  [
    styled("OBSERVED SENDS · latest 20", width, theme.overlay_current()),
    styled("Acceptance is not a read receipt", width, theme.overlay_quiet()),
    ..list.flat_map(visible_messages, fn(item) {
      let chosen = identity(item) == identity(current)
      let marker = case chosen {
        True -> "▸ "
        False -> "  "
      }
      let background = case chosen {
        True -> theme.raised
        False -> theme.graphite
      }
      let primary = style.new(theme.paper, background, style.none())
      let secondary =
        style.new(state_color(item.state), background, style.none())
      let quiet = style.new(theme.quiet, background, style.none())
      [
        styled(marker <> item.source <> " → " <> item.target, width, primary),
        styled("  " <> short_state_label(item.state), width, secondary),
        styled("  " <> one_line_excerpt(item.body), width, quiet),
      ]
    })
  ]
}

fn preview(
  item: agent_messages.Item,
  body_scroll: Int,
  width: Int,
  body_rows: Int,
) -> List(span.Line) {
  let inner = int.max(1, width - 2)
  let body =
    item.body
    |> text_hygiene.multiline
    |> string.split("\n")
    |> list.flat_map(fn(line) { text.wrap(line, inner) })
  let max_scroll = int.max(0, list.length(body) - 1)
  let offset = int.min(int.max(0, body_scroll), max_scroll)
  let extent = case item.body_extent {
    agent_messages.Complete -> "Complete captured body"
    agent_messages.Excerpt -> "Retained excerpt"
  }
  let shade = style.new(theme.paper, theme.raised, style.none())
  [
    styled("MESSAGE PREVIEW", width, theme.overlay_current()),
    styled(" " <> item.source <> " → " <> item.target, width, shade),
    styled(" " <> state_label(item.state) <> " · " <> extent, width, shade),
    styled(
      " revision " <> int.to_string(item.seq) <> " · observed only",
      width,
      style.new(theme.quiet, theme.raised, style.none()),
    ),
    styled("", width, shade),
    ..list.map(list.take(list.drop(body, offset), body_rows), fn(line) {
      styled(" " <> line, width, shade)
    })
  ]
}

fn one_line_excerpt(body: String) -> String {
  body
  |> text_hygiene.single_line
  |> text.truncate(48, "…")
}

fn state_label(state: agent_messages.State) -> String {
  case state {
    agent_messages.SendPending -> "Outcome unknown"
    agent_messages.SendFailed -> "Send failed"
    agent_messages.Accepted -> "Accepted by recipient"
    agent_messages.Started -> "Started recipient run"
  }
}

fn short_state_label(state: agent_messages.State) -> String {
  case state {
    agent_messages.SendPending -> "Unknown"
    agent_messages.SendFailed -> "Failed"
    agent_messages.Accepted -> "Accepted"
    agent_messages.Started -> "Started"
  }
}

fn state_color(state: agent_messages.State) -> style.Color {
  case state {
    agent_messages.SendPending -> theme.quiet
    agent_messages.SendFailed -> theme.danger
    agent_messages.Accepted -> theme.current
    agent_messages.Started -> theme.added
  }
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

fn first(items: List(a)) -> Option(a) {
  items |> list.first |> option_from_result
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(item) -> Some(item)
    Error(Nil) -> None
  }
}
