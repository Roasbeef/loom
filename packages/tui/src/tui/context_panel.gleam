//// The context inspector presents one server-priced projection. Capacity is
//// a measured estimate against the model window, never operation progress.

import etui/span
import etui/style
import etui/text
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui/context_view
import tui/text_hygiene
import tui/theme

/// Produces semantic context rows for the current detail mode.
///
/// ## Examples
///
/// ```gleam
/// // context_panel.lines(context_view.new(), 80)
/// ```
@internal
pub fn lines(state: context_view.State, width: Int) -> List(span.Line) {
  let observation = observation_line(state)
  case state.board {
    None -> styled(observation, theme.overlay_signal(), width)
    Some(board) -> {
      let meter_width = int.min(24, int.max(4, width - 12))
      let filled = int.min(meter_width, board.used * meter_width / board.window)
      let basis = case board.basis {
        "reported_plus_estimate" ->
          "provider usage plus newer-message estimate; includes output"
        _ -> "prompt, tools, and message estimate"
      }
      let boundary = case board.checkpoint_at {
        Some(at) ->
          "Compaction threshold "
          <> count(at)
          <> " · compaction accounting "
          <> count(board.compaction_used)
          <> " · free to threshold "
          <> count(int.max(0, at - board.compaction_used))
        None -> "Automatic compaction disabled"
      }
      let detail = case state.surface {
        context_view.All ->
          list.flatten([
            [heading("ITEM INVENTORY", width)],
            list.flat_map(board.items, fn(item) {
              styled(
                text_hygiene.single_line(item.category <> " · " <> item.name)
                  <> " · ~"
                  <> count(item.tokens),
                theme.overlay_plain(),
                width,
              )
            }),
            styled(
              int.to_string(board.omitted)
                <> " items omitted by the observation bound",
              theme.overlay_quiet(),
              width,
            ),
          ])
        context_view.Overview | context_view.Hidden ->
          styled("a shows bounded item inventory", theme.overlay_quiet(), width)
      }
      list.flatten([
        styled(observation, theme.overlay_signal(), width),
        [
          heading(
            "CONTEXT CAPACITY · " <> text_hygiene.single_line(board.model),
            width,
          ),
        ],
        card(
          "["
            <> string.repeat("█", filled)
            <> string.repeat("░", meter_width - filled)
            <> "] ~"
            <> count(board.used)
            <> " / "
            <> count(board.window),
          width,
        ),
        styled(
          "Estimate basis: "
            <> basis
            <> " · strand "
            <> text_hygiene.single_line(board.strand)
            <> " · durable sequence "
            <> int.to_string(board.as_of),
          theme.overlay_quiet(),
          width,
        ),
        [heading("COMPONENT ESTIMATES · independent of headline", width)],
        list.flat_map(board.categories, fn(item) { component_row(item, width) }),
        [heading("COMPACTION BOUNDARY", width)],
        styled(boundary, theme.overlay_plain(), width),
        styled(
          "Reserved window "
            <> count(board.reserve)
            <> " · free model window "
            <> count(int.max(0, board.window - board.used)),
          theme.overlay_plain(),
          width,
        ),
        styled(
          "Component rows are independent estimates and need not sum to the headline. Transient hooks and unsent input are not reconstructed.",
          theme.overlay_quiet(),
          width,
        ),
        detail,
      ])
    }
  }
}

fn observation_line(state: context_view.State) -> String {
  case state.request, state.notice {
    context_view.Requested, "" ->
      "Refresh pending; previous observation may be stale"
    context_view.Awaiting(_), "" ->
      "Refreshing context; previous observation may be stale"
    context_view.RefreshAfter(_), "" ->
      "Refreshing context; another refresh is pending"
    context_view.Unavailable, "" ->
      "Context observation unavailable from this host"
    context_view.Idle, "" -> "Last server observation"
    _, notice -> notice
  }
}

fn component_row(item: context_view.Item, width: Int) -> List(span.Line) {
  let label = text_hygiene.single_line(item.name)
  let value = "~" <> count(item.tokens)
  case width >= 32 {
    True -> {
      let label_width = int.max(1, width - text.cell_width(value) - 2)
      [
        span.line_new([
          span.span_styled(
            text.pad_right(text.truncate(label, label_width, "…"), label_width),
            theme.overlay_plain(),
          ),
          span.span_styled("  " <> value, theme.overlay_current()),
        ]),
      ]
    }
    False ->
      list.append(
        styled(label, theme.overlay_plain(), width),
        styled(text.pad_left(value, width), theme.overlay_current(), width),
      )
  }
}

fn heading(value: String, width: Int) -> span.Line {
  span.line_new([
    span.span_styled(
      value |> text.truncate(width, "…") |> text.pad_right(width),
      style.new(theme.current, theme.raised, style.bold()),
    ),
  ])
}

fn card(value: String, width: Int) -> List(span.Line) {
  styled(value, style.new(theme.paper, theme.raised, style.none()), width)
  |> list.map(fn(line) {
    let padding = int.max(0, width - span.line_width(line))
    span.Line(
      ..line,
      spans: list.append(line.spans, [
        span.span_styled(
          string.repeat(" ", padding),
          style.new(theme.paper, theme.raised, style.none()),
        ),
      ]),
    )
  })
}

fn styled(
  value: String,
  appearance: style.Style,
  width: Int,
) -> List(span.Line) {
  value
  |> text_hygiene.multiline
  |> string.split("\n")
  |> list.map(fn(line) { span.line_new([span.span_styled(line, appearance)]) })
  |> span.text_new
  |> span.wrap(int.max(1, width))
  |> fn(wrapped) { wrapped.lines }
}

fn count(value: Int) -> String {
  int.to_string(value)
}
