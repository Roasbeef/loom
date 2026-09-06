//// Exact approval text is a local inspection surface, never executable markup.
////
//// The bounded escaped text is captured when the panel opens. A later metadata
//// cut may change the pending record, but cannot silently rewrite the details
//// being inspected. Approve/deny are still explicit commands after closing the
//// panel and use the then-displayed record's exact sequence.

import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/widgets/block
import etui/widgets/paragraph
import gleam/int
import gleam/list
import tui/approval
import tui/theme

/// Bounded literal detail plus a local scroll offset, with no grant authority.
pub opaque type State {
  State(text: String, offset: Int)
}

/// Inspection navigation never sends an approval or denial.
pub type Action {
  /// Continue with the same captured detail and a new viewport.
  Continue(state: State)

  /// Return focus to the composer for an explicit decision command.
  Close
}

/// Captures complete detail or an explicit incomplete/unsupported diagnosis.
///
/// ## Examples
///
/// ```gleam
/// // approval_panel.new(review)
/// ```
pub fn new(review: approval.Review) -> State {
  let detail = case approval.details(review) {
    Ok(text) -> text
    Error(reason) -> reason
  }
  State(detail, 0)
}

/// Scrolls without changing the captured decision or emitting a mutation.
///
/// ## Examples
///
/// ```gleam
/// // approval_panel.update(keys.Down, panel)
/// ```
pub fn update(key: keys.Key, state: State) -> Action {
  case key {
    keys.Escape | keys.Enter -> Close
    keys.Up -> Continue(State(..state, offset: int.max(0, state.offset - 1)))
    keys.Down ->
      Continue(
        State(..state, offset: int.min(approval.detail_limit, state.offset + 1)),
      )
    keys.PageUp ->
      Continue(State(..state, offset: int.max(0, state.offset - 10)))
    keys.PageDown ->
      Continue(
        State(
          ..state,
          offset: int.min(approval.detail_limit, state.offset + 10),
        ),
      )
    keys.Home -> Continue(State(..state, offset: 0))
    keys.End -> Continue(State(..state, offset: approval.detail_limit))
    _ -> Continue(state)
  }
}

/// Renders bounded literal JSON through the existing span and paragraph widgets.
///
/// ## Examples
///
/// ```gleam
/// // approval_panel.render(buffer, screen, panel)
/// ```
pub fn render(buf: buffer.Buffer, screen: Rect, state: State) -> buffer.Buffer {
  let width = int.max(1, int.min(100, screen.size.width - 4))
  let height = int.max(1, screen.size.height - 4)
  let area = geometry.centered_rect(width, height, screen)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title(
      " EXACT APPROVAL · ↑↓ PgUp/PgDn · Esc closes ",
      block.Top,
    )
  let inside = block.inner(area, frame)

  // Wrap only the bounded literal, then select its viewport. No markdown parser
  // can reinterpret a grant path or turn the preview into a link or control.
  let lines =
    span.wrap(
      span.text_new([span.line_plain(state.text)]),
      int.max(1, inside.size.width),
    ).lines
  let offset =
    int.min(state.offset, int.max(0, list.length(lines) - inside.size.height))
  buf
  |> buffer.clear(area)
  |> block.render(area, frame)
  |> paragraph.render_styled(inside, list.drop(lines, offset))
}
