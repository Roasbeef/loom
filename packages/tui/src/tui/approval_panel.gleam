//// The approval dialog owns the exact question displayed when it opened.
////
//// Metadata may change behind the panel, but a decision carries its captured
//// record, including the action, grants and sequence. No choice is selected
//// on opening, so a queued Enter cannot approve a newly arrived request.

import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/widgets/block
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tui/approval
import tui/text_hygiene
import tui/theme

/// Explicit decisions offered beside the exact requested authority.
pub type Choice {
  /// Authorize only the displayed invocation.
  AllowOnce

  /// Remember the displayed filesystem or full-network grants for this session.
  AllowSession

  /// Refuse the displayed invocation's request.
  Deny
}

/// Captured consent, a scroll position and an explicitly selected decision.
pub opaque type State {
  State(
    text: String,
    offset: Int,
    review: approval.Review,
    selected: Option(Choice),
  )
}

/// Navigation preserves the captured question; only Enter after selection decides.
pub type Action {
  /// Continue with the same captured detail and a new viewport.
  Continue(state: State)

  /// Defer this question and return focus to the composer.
  Close

  /// Submit the exact record captured by the dialog, without a fresh lookup.
  Decide(review: approval.Review, choice: Choice)
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
  State(detail, 0, review, None)
}

/// Adds captured owner context without changing the exact consent record.
///
/// ## Examples
///
/// ```gleam
/// // approval_panel.with_context(panel, "Requested by worker · operation 123")
/// ```
@internal
pub fn with_context(state: State, context: String) -> State {
  State(
    ..state,
    text: text_hygiene.single_line(context) <> "\n\n" <> state.text,
  )
}

/// Scrolls the authority or selects a decision before explicitly confirming it.
///
/// ## Examples
///
/// ```gleam
/// // approval_panel.update(keys.Down, panel)
/// ```
pub fn update(key: keys.Key, state: State) -> Action {
  case key {
    keys.Escape -> Close
    keys.Enter ->
      case state.selected {
        None -> Continue(state)
        Some(choice) -> Decide(state.review, choice)
      }
    keys.Right | keys.Tab ->
      Continue(State(..state, selected: Some(next(state.selected))))
    keys.Left ->
      Continue(State(..state, selected: Some(previous(state.selected))))
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

fn next(choice: Option(Choice)) -> Choice {
  case choice {
    None | Some(Deny) -> AllowOnce
    Some(AllowOnce) -> AllowSession
    Some(AllowSession) -> Deny
  }
}

fn previous(choice: Option(Choice)) -> Choice {
  case choice {
    None | Some(AllowOnce) -> Deny
    Some(AllowSession) -> AllowOnce
    Some(Deny) -> AllowSession
  }
}

fn label(choice: Choice, selected: Option(Choice), text: String) -> String {
  case selected == Some(choice) {
    True -> "[ " <> text <> " ]"
    False -> "  " <> text <> "  "
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
      " PERMISSION REQUEST · ↑↓ scroll · ←→ choose · Enter confirm · Esc defer ",
      block.Top,
    )

  // Choices remain visible while the exact grant details scroll independently.
  let inside = block.inner(area, frame)
  let detail =
    geometry.rect_new(
      inside.position.x,
      inside.position.y,
      inside.size.width,
      int.max(1, inside.size.height - 3),
    )
  let buttons =
    geometry.rect_new(
      inside.position.x,
      inside.position.y + int.max(0, inside.size.height - 2),
      inside.size.width,
      int.min(2, inside.size.height),
    )
  let session_note = case approval.rememberable(state.review) {
    Ok(_) ->
      "Session access survives restart; exactly these grants will be remembered."
    Error(reason) -> "Session approval unavailable: " <> reason
  }
  let choices =
    label(AllowOnce, state.selected, "Allow once")
    <> label(AllowSession, state.selected, "Allow for session")
    <> label(Deny, state.selected, "Deny")

  // Wrap only the bounded literal, then select its viewport. No markdown parser
  // can reinterpret a grant path or turn the preview into a link or control.
  let lines =
    span.wrap(
      span.text_new(string.split(state.text, "\n") |> list.map(span.line_plain)),
      int.max(1, detail.size.width),
    ).lines
  let offset =
    int.min(state.offset, int.max(0, list.length(lines) - detail.size.height))
  buf
  |> buffer.clear(area)
  |> block.render(area, frame)
  |> paragraph.render_styled(detail, list.drop(lines, offset))
  |> paragraph.render_styled(buttons, [
    span.line_plain(choices),
    span.line_plain(session_note),
  ])
}
