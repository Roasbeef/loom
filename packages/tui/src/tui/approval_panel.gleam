//// The approval dialog owns the exact question displayed when it opened.
////
//// Metadata may change behind the panel, but a decision carries its captured
//// record, including the action, grants and sequence. No choice is selected
//// on opening, so a queued Enter cannot approve a newly arrived request.
////
//// It is drawn as a full-width block directly above the input frame, under
//// a rule, rather than as a dialog over the transcript: the question, the
//// exact action, the grant and whether session approval exists, then the
//// numbered choices and the keys. `1`, `2` and `3` select a choice and
//// never confirm it; only Enter confirms, so no decision is one keystroke.
//// `d` shows the raw captured request and Escape defers. While it is open
//// the input frame says it is locked.

import etui/buffer
import etui/geometry.{type Rect}
import etui/keys
import etui/span
import etui/style
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import session_view/approval
import session_view/text_hygiene
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

/// The exact record captured when the panel opened.
///
/// The status tells an open question (`Pending`) from a deliberate inspection
/// of a decision that was already made, which is how the client knows whether
/// a later resolution by another client has made the panel stale.
///
/// ## Examples
///
/// ```gleam
/// // approval_panel.review(panel).status == approval.Pending
/// ```
pub fn review(state: State) -> approval.Review {
  state.review
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

    // A number selects its choice, when the choice is offered, and decides
    // nothing: Enter is the one key that sends a decision.
    keys.Char("1") -> select(state, AllowOnce, approvable(state.review))
    keys.Char("2") ->
      select(state, AllowSession, session_approvable(state.review))
    keys.Char("3") -> select(state, Deny, True)
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

fn select(state: State, choice: Choice, offered: Bool) -> Action {
  case offered {
    True -> Continue(State(..state, selected: Some(choice)))
    False -> Continue(state)
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

/// Renders the full-width consent block at the bottom of `area`, which is
/// the screen above the input frame.
///
/// The choices and keys keep their rows while the request's detail scrolls
/// above them, so a long grant never pushes the decision out of view.
///
/// ## Examples
///
/// ```gleam
/// // approval_panel.render(buffer, above_input, panel)
/// ```
pub fn render(
  buf: buffer.Buffer,
  area: Rect,
  state: State,
  waiting waiting: Int,
) -> buffer.Buffer {
  let width = area.size.width
  let panel_width = case width < 74 {
    True -> NarrowPanel
    False -> WidePanel
  }
  let content_width = int.max(1, width - 6)
  let lines = detail_lines(state, panel_width, content_width)

  // The rule, the question, and the blank rows around the choices are
  // chrome; the choices are three rows and the keys one. What is left goes
  // to the request's detail, up to its length. A short screen drops the
  // blank rows before it takes rows from the detail.
  let spacing = case area.size.height >= 18 {
    True -> Spaced
    False -> Tight
  }
  let chrome = case spacing {
    Spaced -> 4 + 3 + 2
    Tight -> 2 + 3 + 1
  }
  let available = int.max(1, area.size.height - chrome)
  let detail_height =
    int.max(1, int.min(list.length(lines), int.min(available, 12)))
  let height = int.min(area.size.height, detail_height + chrome)
  let top = geometry.bottom(area) - height
  let block = geometry.rect_new(area.position.x, top, width, height)
  let max_offset = int.max(0, list.length(lines) - detail_height)
  let offset = case state.scroll {
    FromStart(page) -> int.min(max_offset, page * detail_height)
    FromEnd(pages) -> int.max(0, max_offset - pages * detail_height)
  }
  let once = case approvable(state.review) {
    True -> Enabled
    False -> Disabled
  }
  let session = case session_approvable(state.review) {
    True -> Enabled
    False -> Disabled
  }
  let more = case offset, max_offset {
    0, 0 -> []
    offset, max if offset < max -> ["PgDn more of the request"]
    _, _ -> ["PgUp earlier in the request"]
  }
  let controls = case panel_width {
    NarrowPanel -> ["1-3 ↑↓ select", "Enter confirms", "d raw", "Esc defers"]
    WidePanel ->
      list.flatten([
        ["1-3 or ↑↓ select", "Enter confirms", "d raw request", "Esc defers"],
        more,
      ])
  }
  let gap = case spacing {
    Spaced -> [blank()]
    Tight -> []
  }
  let rows =
    list.flatten([
      [rule(width), heading(state, waiting, width)],
      gap,
      list.map(list.take(list.drop(lines, offset), detail_height), indent),
      gap,
      [
        choice_line(
          AllowOnce,
          "1",
          case state.review.tool {
            "loom_config" -> "Approve edit"
            _ -> "Allow once"
          },
          once,
          state,
          width,
        ),
        choice_line(
          AllowSession,
          "2",
          "Allow for session",
          session,
          state,
          width,
        ),
        choice_line(Deny, "3", "Deny", Enabled, state, width),
      ],
      gap,
      [hints(controls, width)],
    ])

  // The block clears its rows only: the transcript above it keeps its own.
  buf
  |> buffer.clear(block)
  |> paragraph.render_styled(block, rows)
}

// Whether the block can spare blank rows around its sections.
type Spacing {
  Spaced
  Tight
}

fn rule(width: Int) -> span.Line {
  span.line_new([
    span.span_styled(
      string.repeat("─", width),
      style.new(theme.divider, style.Default, style.none()),
    ),
  ])
}

// The question in bold beside the danger mark, as the transcript's own
// approval row draws it, so the two read as one thing, after the strand
// whose call asked. When more questions wait, the right end says which of
// them this is.
fn heading(state: State, waiting: Int, width: Int) -> span.Line {
  let approval.Presentation(question, _, _) = state.presentation
  let asker = case state.review.strand {
    Some(strand) -> text_hygiene.single_line(strand) <> " · "
    None -> ""
  }
  let place = case waiting > 1 {
    True -> "1 of " <> int.to_string(waiting) <> " "
    False -> ""
  }
  let room = width - 3 - string.length(place) - 1
  let words = fit(asker <> text_hygiene.single_line(question), room)
  let gap = int.max(1, width - 3 - string.length(words) - string.length(place))
  span.line_new([
    span.span_styled(
      " ? ",
      style.new(theme.danger, style.Default, style.bold()),
    ),
    span.span_styled(words, style.new(theme.paper, style.Default, style.bold())),
    span.span_plain(string.repeat(" ", gap)),
    span.span_styled(place, theme.quiet_text()),
  ])
}

fn fit(value: String, width: Int) -> String {
  case string.length(value) <= width {
    True -> value
    False -> string.slice(value, 0, int.max(0, width - 1)) <> "…"
  }
}

fn blank() -> span.Line {
  span.line_new([])
}

fn indent(line: span.Line) -> span.Line {
  span.line_new([span.span_plain("   "), ..line.spans])
}

// Joins the key hints with ` · `, skipping one that does not fit rather
// than cutting it in half.
fn hints(items: List(String), width: Int) -> span.Line {
  let joined =
    list.fold(items, "", fn(drawn, item) {
      let next = case drawn {
        "" -> " " <> item
        _ -> drawn <> " · " <> item
      }
      case string.length(next) <= width {
        True -> next
        False -> drawn
      }
    })
  span.line_new([
    span.span_styled(
      joined,
      style.new(theme.quiet, style.Default, style.none()),
    ),
  ])
}

fn detail_lines(
  state: State,
  panel_width: PanelWidth,
  width: Int,
) -> List(span.Line) {
  let context = case state.context, panel_width, state.detail_mode {
    NoRequestContext, _, _ -> []
    RequestContextUnavailable(reason), _, _ ->
      styled_lines(reason, quiet(), width)
    CapturedRequest(owner, operation), _, Raw ->
      styled_lines(
        "Requested by " <> owner <> " · operation " <> operation,
        style.new(theme.current, style.Default, style.none()),
        width,
      )
    CapturedRequest(owner, _), NarrowPanel, Readable ->
      styled_lines(
        "From " <> owner,
        style.new(theme.current, style.Default, style.none()),
        width,
      )
    CapturedRequest(owner, _), WidePanel, Readable ->
      styled_lines(
        "Requested by " <> owner,
        style.new(theme.current, style.Default, style.none()),
        width,
      )
  }
  case state.detail_mode {
    Raw ->
      list.flatten([
        context,
        [
          span.line_new([
            span.span_styled("raw request", label()),
          ]),
        ],
        styled_lines(state.raw, plain(), width),
      ])
    Readable -> {
      let approval.Presentation(_, action, authority) = state.presentation
      let session = case approval.rememberable(state.review) {
        Ok(_) ->
          styled_lines(
            approval.remembered_authority(state.review),
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

      // The question is the block's own heading, so the detail starts at
      // the action and the grant.
      list.flatten([
        context,
        action_lines(state.review.tool, action, width),
        [span.line_new([])],
        [
          span.line_new([
            span.span_styled(
              case state.review.tool {
                "loom_config" -> "configuration consent"
                _ -> "grant"
              },
              label(),
            ),
          ]),
        ],
        authority
          |> list.map(fn(line) { styled_lines(line, plain(), width) })
          |> list.flatten,
        session,
      ])
    }
  }
}

// Configuration rows preserve literal text while removal and addition own color.
fn action_lines(tool: String, text: String, width: Int) {
  case tool {
    "loom_config" ->
      text
      |> string.split("\n")
      |> list.flat_map(fn(row) {
        let color = case
          string.starts_with(row, "- "),
          string.starts_with(row, "+ ")
        {
          True, _ -> theme.danger
          _, True -> theme.added
          _, _ -> theme.paper
        }
        styled_lines(row, style.new(color, style.Default, style.none()), width)
      })
    _ -> styled_lines(text, plain(), width)
  }
}

fn plain() -> style.Style {
  style.new(theme.paper, style.Default, style.none())
}

fn quiet() -> style.Style {
  style.new(theme.quiet, style.Default, style.none())
}

fn label() -> style.Style {
  style.new(theme.quiet, style.Default, style.bold())
}

fn styled_lines(text: String, appearance: style.Style, width: Int) {
  text
  |> string.split("\n")
  |> list.map(fn(line) { span.line_new([span.span_styled(line, appearance)]) })
  |> span.text_new
  |> span.wrap(width)
  |> fn(wrapped) { wrapped.lines }
}

// One numbered choice. The number is amber, the label plain; the selected
// choice is the raised bar, and an unavailable one says so and is quiet.
fn choice_line(
  choice: Choice,
  number: String,
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
  let ground = case selected {
    True -> theme.raised
    False -> style.Default
  }
  let marker = case selected {
    True -> " › "
    False -> "   "
  }
  let look = case selected, availability {
    True, Enabled -> style.new(theme.paper, ground, style.bold())
    True, Disabled | False, Disabled ->
      style.new(theme.quiet, ground, style.none())
    False, Enabled -> style.new(theme.paper, ground, style.none())
  }
  let used = 3 + string.length(number) + 2 + string.length(label)
  span.line_new([
    span.span_styled(marker, style.new(theme.signal, ground, style.bold())),
    span.span_styled(
      number <> "  ",
      style.new(theme.signal, ground, style.bold()),
    ),
    span.span_styled(label, look),
    span.span_styled(string.repeat(" ", int.max(0, width - used)), look),
  ])
}
