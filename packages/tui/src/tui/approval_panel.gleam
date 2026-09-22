//// The approval dialog owns the exact question displayed when it opened.
////
//// Metadata may change behind the panel, but a decision carries its captured
//// record, including the action, grants and sequence. No choice is selected
//// on opening, so a queued Enter cannot approve a newly arrived request.

import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/style
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

type Availability {
  Enabled
  Disabled
}

type ScrollPosition {
  FromStart(page: Int)
  FromEnd(pages: Int)
}

/// Captured consent, a scroll position and an explicitly selected decision.
pub opaque type State {
  State(
    presentation: approval.Presentation,
    raw: String,
    context: RequestContext,
    detail_mode: DetailMode,
    scroll: ScrollPosition,
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
  let presentation = case approval.presentation(review) {
    Ok(presentation) -> presentation
    Error(reason) ->
      approval.Presentation("Approval unavailable", reason, [
        "Only Deny is available.",
      ])
  }
  State(
    presentation,
    raw,
    NoRequestContext,
    Readable,
    FromStart(0),
    review,
    None,
  )
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
          scroll: FromStart(0),
        ),
      )
    keys.Right | keys.Tab | keys.Down ->
      Continue(State(..state, selected: Some(next(state))))
    keys.Left | keys.Up ->
      Continue(State(..state, selected: Some(previous(state))))
    keys.PageUp -> Continue(State(..state, scroll: previous_page(state.scroll)))
    keys.PageDown -> Continue(State(..state, scroll: next_page(state.scroll)))
    keys.Home -> Continue(State(..state, scroll: FromStart(0)))
    keys.End -> Continue(State(..state, scroll: FromEnd(0)))
    _ -> Continue(state)
  }
}

fn previous_page(position: ScrollPosition) -> ScrollPosition {
  case position {
    FromStart(page) -> FromStart(int.max(0, page - 1))
    FromEnd(pages) -> FromEnd(pages + 1)
  }
}

fn next_page(position: ScrollPosition) -> ScrollPosition {
  case position {
    FromStart(page) -> FromStart(page + 1)
    FromEnd(0) -> FromEnd(0)
    FromEnd(pages) -> FromEnd(pages - 1)
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

/// Renders a compact, styled consent sheet over the transcript tail.
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
  let content_width = int.max(1, width - 4)
  let lines = detail_lines(state, panel_width, content_width)
  let wanted_height = int.max(12, list.length(lines) + 7)
  let max_height = case screen.size.height < 14 {
    True -> screen.size.height
    False -> int.max(10, int.min(18, screen.size.height * 3 / 5))
  }
  let height = int.max(1, int.min(wanted_height, max_height))
  let area =
    geometry.rect_new(
      screen.position.x + int.max(0, { screen.size.width - width } / 2),
      screen.position.y + int.max(0, screen.size.height - height),
      width,
      height,
    )
  let band =
    geometry.rect_new(
      screen.position.x,
      area.position.y,
      screen.size.width,
      area.size.height,
    )
  let title = case panel_width {
    NarrowPanel -> " Permission required · Esc defer "
    WidePanel -> " Permission required · Esc defers "
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
  let wanted_button_height = 5
  let button_height =
    int.min(wanted_button_height, int.max(1, inside.size.height - 1))
  let detail_height = int.max(1, inside.size.height - button_height)
  let detail =
    geometry.rect_new(
      inside.position.x + 1,
      inside.position.y,
      int.max(1, inside.size.width - 2),
      detail_height,
    )
  let buttons =
    geometry.rect_new(
      inside.position.x,
      inside.position.y + detail_height,
      inside.size.width,
      int.max(0, inside.size.height - detail_height),
    )
  let max_offset = int.max(0, list.length(lines) - detail.size.height)
  let offset = case state.scroll {
    FromStart(page) -> int.min(max_offset, page * detail.size.height)
    FromEnd(pages) -> int.max(0, max_offset - pages * detail.size.height)
  }
  let once = case approvable(state.review) {
    True -> Enabled
    False -> Disabled
  }
  let session = case session_approvable(state.review) {
    True -> Enabled
    False -> Disabled
  }
  let choice_lines = [
    choice_line(AllowOnce, "Allow once", once, state, inside.size.width),
    choice_line(
      AllowSession,
      "Allow for session",
      session,
      state,
      inside.size.width,
    ),
    choice_line(Deny, "Deny", Enabled, state, inside.size.width),
  ]
  let more = case offset, max_offset {
    0, 0 -> ""
    offset, max if offset < max -> "PgDn more request details"
    _, _ -> "PgUp earlier request details"
  }
  let controls = case panel_width {
    NarrowPanel -> "↑↓ choose · Enter · d raw"
    WidePanel -> "↑↓ choose · Enter confirm · d raw · Esc defer"
  }

  // Wrap only the bounded literal, then select its viewport. No markdown parser
  // can reinterpret a grant path or turn the preview into a link or control.
  buf
  |> buffer.clear(band)
  |> block.render(area, frame)
  |> paragraph.render_styled(detail, list.drop(lines, offset))
  |> paragraph.render_styled(
    buttons,
    list.append(choice_lines, [
      span.line_new([span.span_styled(more, theme.overlay_signal())]),
      span.line_new([span.span_styled(controls, theme.overlay_quiet())]),
    ]),
  )
}

fn detail_lines(
  state: State,
  panel_width: PanelWidth,
  width: Int,
) -> List(span.Line) {
  let context = case state.context, panel_width, state.detail_mode {
    NoRequestContext, _, _ -> []
    RequestContextUnavailable(reason), _, _ ->
      styled_lines(reason, theme.overlay_quiet(), width)
    CapturedRequest(owner, operation), _, Raw ->
      styled_lines(
        "Requested by " <> owner <> " · operation " <> operation,
        theme.overlay_current(),
        width,
      )
    CapturedRequest(owner, _), NarrowPanel, Readable ->
      styled_lines("From " <> owner, theme.overlay_current(), width)
    CapturedRequest(owner, _), WidePanel, Readable ->
      styled_lines("Requested by " <> owner, theme.overlay_current(), width)
  }
  case state.detail_mode {
    Raw ->
      list.flatten([
        context,
        [
          span.line_new([
            span.span_styled("Raw captured request", theme.overlay_signal()),
          ]),
        ],
        styled_lines(state.raw, theme.overlay_plain(), width),
      ])
    Readable -> {
      let approval.Presentation(question, action, authority) =
        state.presentation
      let session = case approval.rememberable(state.review) {
        Ok(_) ->
          styled_lines(
            "Session approval persists across restart.",
            theme.overlay_quiet(),
            width,
          )
        Error(reason) ->
          styled_lines(
            "Session option unavailable: " <> reason,
            theme.overlay_quiet(),
            width,
          )
      }
      list.flatten([
        styled_lines(question, theme.overlay_signal(), width),
        context,
        [span.line_new([span.span_styled("Action", theme.overlay_quiet())])],
        card_lines(
          "  ▏ " <> action,
          style.new(theme.paper, theme.raised, style.none()),
          width,
        ),
        [
          span.line_new([
            span.span_styled("Access requested", theme.overlay_quiet()),
          ]),
        ],
        authority
          |> list.map(fn(line) {
            styled_lines("  " <> line, theme.overlay_plain(), width)
          })
          |> list.flatten,
        session,
      ])
    }
  }
}

fn styled_lines(text: String, appearance: style.Style, width: Int) {
  text
  |> string.split("\n")
  |> list.map(fn(line) { span.line_new([span.span_styled(line, appearance)]) })
  |> span.text_new
  |> span.wrap(width)
  |> fn(wrapped) { wrapped.lines }
}

fn card_lines(text: String, appearance: style.Style, width: Int) {
  text
  |> styled_lines(appearance, width)
  |> list.map(fn(line) {
    let padding = int.max(0, width - span.line_width(line))
    span.Line(
      ..line,
      spans: list.append(line.spans, [
        span.span_styled(string.repeat(" ", padding), appearance),
      ]),
    )
  })
}

fn choice_line(
  choice: Choice,
  label: String,
  availability: Availability,
  state: State,
  width: Int,
) -> span.Line {
  let selected = state.selected == Some(choice)
  let label = case availability {
    Enabled -> label
    Disabled -> label <> " (unavailable)"
  }
  let marker = case selected {
    True -> "› "
    False -> "  "
  }
  let content = marker <> label
  let content =
    content <> string.repeat(" ", int.max(0, width - string.length(content)))
  let appearance = case selected, availability {
    True, Enabled -> style.new(theme.paper, theme.raised, style.bold())
    True, Disabled | False, Disabled -> theme.overlay_quiet()
    False, Enabled -> theme.overlay_plain()
  }
  span.line_new([span.span_styled(content, appearance)])
}
