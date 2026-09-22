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

/// Which complete representation owns the scrolling detail viewport.
pub type DetailMode {
  /// Human-readable labels with every authority value preserved literally.
  Readable

  /// The complete captured request encoded as escaped JSON.
  Raw
}

/// Captured requester identity kept separate from its operation identifier.
pub type RequestContext {
  /// No requester metadata was attached by the caller.
  NoRequestContext

  /// Both values came from the exact captured escalation revision.
  CapturedRequest(owner: String, operation: String)

  /// The exact capture did not carry a complete requester scope.
  RequestContextUnavailable(reason: String)
}

type PanelWidth {
  NarrowPanel
  WidePanel
}

/// Captured consent, a scroll position and an explicitly selected decision.
pub opaque type State {
  State(
    readable: String,
    raw: String,
    context: RequestContext,
    detail_mode: DetailMode,
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
  let raw = case approval.details(review) {
    Ok(text) -> text
    Error(reason) -> reason
  }
  let readable = case approval.readable_details(review) {
    Ok(text) -> text
    Error(reason) -> "Approval unavailable: " <> reason
  }
  State(readable, raw, NoRequestContext, Readable, 0, review, None)
}

/// Adds captured owner context without changing the exact consent record.
///
/// ## Examples
///
/// ```gleam
/// // approval_panel.with_context(panel, CapturedRequest("worker", "123"))
/// ```
@internal
pub fn with_context(state: State, context: RequestContext) -> State {
  let context = case context {
    NoRequestContext -> NoRequestContext
    CapturedRequest(owner, operation) ->
      CapturedRequest(
        text_hygiene.single_line(owner),
        text_hygiene.single_line(operation),
      )
    RequestContextUnavailable(reason) ->
      RequestContextUnavailable(text_hygiene.single_line(reason))
  }
  State(..state, context:)
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
    keys.Char("d") | keys.Ctrl("g") ->
      Continue(
        State(
          ..state,
          detail_mode: case state.detail_mode {
            Readable -> Raw
            Raw -> Readable
          },
          offset: 0,
        ),
      )
    keys.Right | keys.Tab ->
      Continue(State(..state, selected: Some(next(state))))
    keys.Left -> Continue(State(..state, selected: Some(previous(state))))
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

fn next(state: State) -> Choice {
  case
    state.selected,
    approvable(state.review),
    session_approvable(state.review)
  {
    None, True, _ | Some(Deny), True, _ -> AllowOnce
    Some(AllowOnce), _, True -> AllowSession
    Some(AllowOnce), _, False | Some(AllowSession), _, _ -> Deny
    None, False, _ | Some(Deny), False, _ -> Deny
  }
}

fn previous(state: State) -> Choice {
  case
    state.selected,
    approvable(state.review),
    session_approvable(state.review)
  {
    None, _, _ | Some(AllowOnce), _, _ -> Deny
    Some(AllowSession), _, _ -> AllowOnce
    Some(Deny), True, True -> AllowSession
    Some(Deny), True, False -> AllowOnce
    Some(Deny), False, _ -> Deny
  }
}

fn approvable(review: approval.Review) -> Bool {
  case approval.approve(0, review) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn session_approvable(review: approval.Review) -> Bool {
  case approval.approve_for_session(0, review) {
    Ok(_) -> True
    Error(_) -> False
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
  let width = int.max(1, int.min(96, screen.size.width))
  let panel_width = case width < 74 {
    True -> NarrowPanel
    False -> WidePanel
  }
  let body = detail_text(state, panel_width)
  let wrapped =
    span.wrap(
      span.text_new(string.split(body, "\n") |> list.map(span.line_plain)),
      int.max(1, width - 2),
    ).lines
  let wanted_height = int.max(10, list.length(wrapped) + 6)
  let max_height = case screen.size.height < 14 {
    True -> screen.size.height
    False -> int.max(10, int.min(16, screen.size.height * 3 / 5))
  }
  let height = int.max(1, int.min(wanted_height, max_height))
  let area =
    geometry.rect_new(
      screen.position.x + int.max(0, { screen.size.width - width } / 2),
      screen.position.y + int.max(0, screen.size.height - height),
      width,
      height,
    )
  let title = case panel_width {
    NarrowPanel -> " Permission · d details · Esc defer "
    WidePanel -> " Permission request · d/Ctrl+g details · Esc defer "
  }

  // The frame sits at the terminal bottom, leaving every row above it intact.
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.signal, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title(title, block.Top)

  // Choices remain visible while the exact grant details scroll independently.
  let inside = block.inner(area, frame)
  let wanted_button_height = case panel_width {
    NarrowPanel -> 5
    WidePanel -> 3
  }
  let button_height =
    int.min(wanted_button_height, int.max(1, inside.size.height - 1))
  let detail_height = int.max(1, inside.size.height - button_height)
  let detail =
    geometry.rect_new(
      inside.position.x,
      inside.position.y,
      inside.size.width,
      detail_height,
    )
  let buttons =
    geometry.rect_new(
      inside.position.x,
      inside.position.y + detail_height,
      inside.size.width,
      int.max(0, inside.size.height - detail_height),
    )
  let session_note = case approval.rememberable(state.review) {
    Ok(_) ->
      "Session access survives restart; exactly these grants will be remembered."
    Error(reason) -> "Session approval unavailable: " <> reason
  }
  let once = case approvable(state.review) {
    True -> label(AllowOnce, state.selected, "Allow once")
    False -> "  Allow once (unavailable)  "
  }
  let session = case session_approvable(state.review) {
    True -> label(AllowSession, state.selected, "Allow for session")
    False -> "  Allow for session (unavailable)  "
  }
  let deny = label(Deny, state.selected, "Deny")
  let choice_lines = case panel_width {
    NarrowPanel -> [once, session, deny]
    WidePanel -> [once <> session <> deny]
  }
  let controls = case panel_width {
    NarrowPanel -> "Tab choose · Enter · ↑↓ scroll"
    WidePanel -> "←/→ or Tab choose · Enter confirm · ↑/↓ scroll"
  }

  // Wrap only the bounded literal, then select its viewport. No markdown parser
  // can reinterpret a grant path or turn the preview into a link or control.
  let lines = wrapped
  let offset =
    int.min(state.offset, int.max(0, list.length(lines) - detail.size.height))
  buf
  |> buffer.clear(area)
  |> block.render(area, frame)
  |> paragraph.render_styled(detail, list.drop(lines, offset))
  |> paragraph.render_styled(
    buttons,
    list.append(choice_lines |> list.map(span.line_plain), [
      span.line_plain(session_note),
      span.line_plain(controls),
    ]),
  )
}

fn detail_text(state: State, panel_width: PanelWidth) -> String {
  let detail = case state.detail_mode {
    Raw -> "Raw captured request:\n" <> state.raw
    Readable -> state.readable
  }
  let context = case state.context, state.detail_mode {
    NoRequestContext, _ -> ""
    RequestContextUnavailable(reason), _ -> reason
    CapturedRequest(owner, operation), Raw ->
      "Requested by " <> owner <> " · operation " <> operation
    CapturedRequest(owner, _), Readable ->
      case panel_width {
        NarrowPanel -> "From " <> owner
        WidePanel -> "Requested by " <> owner
      }
  }
  case context {
    "" -> detail
    context -> context <> "\n" <> detail
  }
}
