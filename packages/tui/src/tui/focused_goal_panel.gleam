//// The explicit session-goal inspector.
////
//// The server owns the board and the terminal owns only its viewport. The
//// panel therefore keeps an observation, a bounded scroll offset, and a
//// worded read state; it never predicts a mutation. Pause and continue leave
//// the displayed board in place until the mutation's correlated reply
//// replaces it.

import etui/buffer
import etui/geometry
import etui/keys
import etui/span
import etui/style
import etui/widgets/block
import etui/widgets/paragraph
import gleam/bool
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tui/goal_view
import tui/text_hygiene
import tui/theme

/// Whether the command lane already owns a goal request.
pub type Availability {
  /// Refresh and status-changing actions may be issued.
  Ready

  /// A correlated goal reply must arrive before another action is accepted.
  Pending
}

/// An explicit key action owned by the inspector.
pub type Action {
  /// Keep the inspector open with its updated viewport.
  Continue(state: State)

  /// Return focus to the unchanged composer.
  Close

  /// Request a current board through the ordinary auxiliary-read lane.
  Refresh

  /// Ask the advisor-owned goal loop to pause.
  Pause

  /// Ask the advisor-owned goal loop to continue.
  Resume
}

/// One observed board and its independent viewport.
pub opaque type State {
  State(board: Option(goal_view.Board), scroll: Int, observation: Observation)
}

type Observation {
  Observed(label: String)
  Unavailable(label: String)
}

type PanelLayout {
  CompactLayout(
    card: geometry.Rect,
    content: geometry.Rect,
    controls: geometry.Rect,
  )

  FramedLayout(
    card: geometry.Rect,
    content: geometry.Rect,
    controls: geometry.Rect,
  )
}

type Density {
  Compact
  Roomy
}

/// Opens an inspector from the last server observation, if one exists.
///
/// ## Examples
///
/// ```gleam
/// // focused_goal_panel.new(option.None, "reading current goal")
/// ```
pub fn new(board: Option(goal_view.Board), observation: String) -> State {
  State(board:, scroll: 0, observation: Observed(observation))
}

/// Replaces the board after a correlated reply and retains a valid viewport.
///
/// ## Examples
///
/// ```gleam
/// // focused_goal_panel.observe(panel, board)
/// ```
pub fn observe(state: State, board: goal_view.Board) -> State {
  State(
    ..state,
    board: Some(board),
    observation: Observed("Last server observation"),
  )
}

/// Keeps the last board while labelling why a refresh could not replace it.
///
/// ## Examples
///
/// ```gleam
/// // focused_goal_panel.unavailable(panel, "conversation disconnected")
/// ```
pub fn unavailable(state: State, reason: String) -> State {
  State(
    ..state,
    scroll: 0,
    observation: Unavailable(
      "Observation not refreshed · " <> text_hygiene.single_line(reason),
    ),
  )
}

/// Returns the board retained by this inspector.
///
/// ## Examples
///
/// ```gleam
/// // focused_goal_panel.board(panel)
/// ```
pub fn board(state: State) -> Option(goal_view.Board) {
  state.board
}

/// Handles only keys owned by the goal card.
///
/// Page movement uses the actual panel geometry, so a small terminal cannot
/// skip content by applying the page size of a larger layout.
///
/// ## Examples
///
/// ```gleam
/// // focused_goal_panel.update(keys.PageDown, panel, area, Ready)
/// ```
pub fn update(
  key: keys.Key,
  state: State,
  area: geometry.Rect,
  availability: Availability,
) -> Action {
  let step = viewport_rows(area)
  let maximum = max_scroll(state, area)
  let state = State(..state, scroll: int.min(state.scroll, maximum))
  case key {
    keys.Escape -> Close
    keys.Char("r") -> available(availability, Refresh, state)
    keys.Char("p") -> status_action(state, availability, Pause)
    keys.Char("c") -> status_action(state, availability, Resume)
    keys.PageUp ->
      Continue(State(..state, scroll: int.max(0, state.scroll - step)))
    keys.PageDown ->
      Continue(State(..state, scroll: int.min(maximum, state.scroll + step)))
    keys.Home -> Continue(State(..state, scroll: 0))
    keys.End -> Continue(State(..state, scroll: maximum))
    _ -> Continue(state)
  }
}

fn available(
  availability: Availability,
  action: Action,
  state: State,
) -> Action {
  case availability {
    Ready -> action
    Pending -> Continue(state)
  }
}

fn status_action(
  state: State,
  availability: Availability,
  action: Action,
) -> Action {
  case state.board, action {
    Some(goal_view.Pinned(status: goal_view.Active, ..)), Pause ->
      available(availability, Pause, state)
    Some(goal_view.Pinned(status: goal_view.Paused(..), ..)), Resume
    | Some(goal_view.Pinned(status: goal_view.Limited(..), ..)), Resume
    -> available(availability, Resume, state)
    None, _
    | Some(goal_view.NoGoal(..)), _
    | Some(goal_view.Pinned(status: goal_view.Complete, ..)), _
    | Some(goal_view.Pinned(status: goal_view.Active, ..)), Resume
    | Some(goal_view.Pinned(status: goal_view.Paused(..), ..)), Pause
    | Some(goal_view.Pinned(status: goal_view.Limited(..), ..)), Pause
    -> Continue(state)
    _, Continue(_) | _, Close | _, Refresh -> Continue(state)
  }
}

/// Renders a raised goal card over the conversation while leaving the
/// composer below it visible.
///
/// ## Examples
///
/// ```gleam
/// // focused_goal_panel.render(buffer, body, panel, Ready)
/// ```
pub fn render(
  buf: buffer.Buffer,
  area: geometry.Rect,
  state: State,
  availability: Availability,
) -> buffer.Buffer {
  use <- bool.guard(area.size.width <= 0 || area.size.height <= 0, buf)
  let layout = panel_layout(area)
  let #(card, content, controls) = layout_areas(layout)
  let frame =
    block.block_new()
    |> block.with_border(block.Rounded)
    |> block.with_colors(theme.current, theme.graphite)
    |> block.with_bg_fill
    |> block.with_title(" Session goal · Esc back ", block.Top)

  // Content owns paging while the control row remains fixed at the bottom.
  let rows = lines(state, int.max(1, content.size.width), content.size.height)
  let maximum = int.max(0, list.length(rows) - content.size.height)
  let offset = int.min(maximum, state.scroll)
  let rendered = buf |> buffer.clear(area)
  let rendered = case layout {
    CompactLayout(..) -> rendered
    FramedLayout(..) -> block.render(rendered, card, frame)
  }
  rendered
  |> paragraph.render_styled(content, list.drop(rows, offset))
  |> paragraph.render_styled(controls, [control_line(state, availability)])
}

fn viewport_rows(area: geometry.Rect) -> Int {
  let #(_, content, _) = layout_areas(panel_layout(area))
  content.size.height
}

fn max_scroll(state: State, area: geometry.Rect) -> Int {
  let #(_, content, _) = layout_areas(panel_layout(area))
  int.max(
    0,
    list.length(lines(state, content.size.width, content.size.height))
      - content.size.height,
  )
}

fn panel_layout(area: geometry.Rect) -> PanelLayout {
  case area.size.height < 8 || area.size.width < 20 {
    True -> build_layout(area, CompactLayout)
    False -> {
      let horizontal = case area.size.width >= 70 {
        True -> 2
        False -> 0
      }
      let card =
        geometry.rect_new(
          area.position.x + horizontal,
          area.position.y,
          int.max(1, area.size.width - horizontal * 2),
          area.size.height,
        )
      let frame = block.block_new() |> block.with_border(block.Rounded)
      build_layout(block.inner(card, frame), fn(_, content, controls) {
        FramedLayout(card, content, controls)
      })
    }
  }
}

fn build_layout(
  inside: geometry.Rect,
  finish: fn(geometry.Rect, geometry.Rect, geometry.Rect) -> PanelLayout,
) -> PanelLayout {
  let controls_height = case inside.size.height >= 3 {
    True -> 1
    False -> 0
  }
  let content =
    geometry.rect_new(
      inside.position.x,
      inside.position.y,
      inside.size.width,
      int.max(1, inside.size.height - controls_height),
    )
  let controls =
    geometry.rect_new(
      inside.position.x,
      inside.position.y + content.size.height,
      inside.size.width,
      controls_height,
    )
  finish(inside, content, controls)
}

fn layout_areas(
  layout: PanelLayout,
) -> #(geometry.Rect, geometry.Rect, geometry.Rect) {
  case layout {
    CompactLayout(card:, content:, controls:)
    | FramedLayout(card:, content:, controls:) -> #(card, content, controls)
  }
}

fn lines(state: State, width: Int, height: Int) -> List(span.Line) {
  let density = case height <= 6 {
    True -> Compact
    False -> Roomy
  }
  let observation = case state.observation {
    Observed(label) -> styled_lines(label, theme.overlay_quiet(), width)
    Unavailable(label) -> styled_lines(label, theme.overlay_signal(), width)
  }
  let body = case state.board {
    None -> [
      heading("Goal unavailable", width),
      ..styled_lines(
        "No server observation has been received.",
        theme.overlay_plain(),
        width,
      )
    ]
    Some(board) -> board_lines(board, width, density)
  }
  case state.observation {
    Observed(_) -> list.append(body, observation)
    Unavailable(_) -> list.append(observation, body)
  }
}

fn board_lines(
  board: goal_view.Board,
  width: Int,
  density: Density,
) -> List(span.Line) {
  case board {
    goal_view.NoGoal(..) -> [
      heading("No goal pinned", width),
      ..styled_lines(
        "Use /goal <objective> to pin work for advisor review.",
        theme.overlay_plain(),
        width,
      )
    ]
    goal_view.Pinned(
      status:,
      because:,
      objective:,
      token_budget:,
      tokens_used:,
      cost_used:,
      continuations:,
      created_ms:,
      updated_ms:,
      reviewer_note:,
      check:,
      last_check:,
      observed_at_ms:,
    ) -> {
      let introduction = case density {
        Compact ->
          list.append(
            styled_lines(
              goal_view.status_word(status)
                <> " · "
                <> text_hygiene.single_line(because),
              status_style(status),
              width,
            ),
            card_lines(text_hygiene.multiline(objective), width),
          )
        Roomy ->
          list.flatten([
            [heading("Status", width)],
            styled_lines(
              goal_view.status_word(status)
                <> " · "
                <> text_hygiene.single_line(because),
              status_style(status),
              width,
            ),
            [heading("Objective", width)],
            card_lines(text_hygiene.multiline(objective), width),
          ])
      }
      list.append(
        introduction,
        list.flatten([
          [heading("Budget consumption", width)],
          styled_lines(
            int.to_string(tokens_used)
              <> " of "
              <> int.to_string(token_budget)
              <> " tokens consumed · "
              <> money(cost_used)
              <> " · "
              <> int.to_string(continuations)
              <> " continuations",
            theme.overlay_plain(),
            width,
          ),
          styled_lines(
            "Pinned "
              <> duration(observed_at_ms - created_ms)
              <> " ago · last change "
              <> duration(observed_at_ms - updated_ms)
              <> " ago",
            theme.overlay_quiet(),
            width,
          ),
          check_lines(check, last_check, observed_at_ms, width),
          note_lines(reviewer_note, width),
        ]),
      )
    }
  }
}

fn check_lines(
  pinned: Option(String),
  last: Option(goal_view.CheckRun),
  observed: Int,
  width: Int,
) -> List(span.Line) {
  case pinned, last {
    None, None -> []
    Some(command), None ->
      list.flatten([
        [heading("Latest check", width)],
        styled_lines(
          text_hygiene.multiline(command),
          theme.overlay_plain(),
          width,
        ),
        styled_lines("Not run yet", theme.overlay_quiet(), width),
      ])
    None, Some(run) | Some(_), Some(run) -> {
      let goal_view.CheckRun(
        command:,
        status:,
        not_finished:,
        output:,
        ran_at_ms:,
      ) = run
      let result = case status, not_finished {
        Some(code), _ -> "Exit status " <> int.to_string(code)
        None, Some(reason) -> text_hygiene.single_line(reason)
        None, None -> "No result"
      }
      let output = case output {
        "" -> []
        text -> [
          heading("Output", width),
          ..card_lines(text_hygiene.multiline(text), width)
        ]
      }
      list.flatten([
        [heading("Latest check", width)],
        styled_lines(
          text_hygiene.multiline(command),
          theme.overlay_plain(),
          width,
        ),
        styled_lines(
          result <> " · ran " <> duration(observed - ran_at_ms) <> " ago",
          check_style(status),
          width,
        ),
        output,
      ])
    }
  }
}

fn note_lines(note: Option(String), width: Int) -> List(span.Line) {
  case note {
    None -> []
    Some(text) -> [
      heading("Reviewer feedback", width),
      ..card_lines(text_hygiene.multiline(text), width)
    ]
  }
}

fn control_line(state: State, availability: Availability) -> span.Line {
  let action = case state.board {
    Some(goal_view.Pinned(status: goal_view.Active, ..)) -> "p pause"
    Some(goal_view.Pinned(status: goal_view.Paused(..), ..))
    | Some(goal_view.Pinned(status: goal_view.Limited(..), ..)) -> "c continue"
    None
    | Some(goal_view.NoGoal(..))
    | Some(goal_view.Pinned(status: goal_view.Complete, ..)) -> ""
  }
  let controls = case action {
    "" -> "r refresh · PgUp/PgDn/Home/End"
    value -> value <> " · r refresh · PgUp/PgDn/Home/End"
  }
  let controls = case availability {
    Ready -> controls
    Pending -> "Waiting for server reply · actions disabled"
  }
  span.line_new([span.span_styled(controls, theme.overlay_signal())])
}

fn heading(text: String, width: Int) -> span.Line {
  case list.first(styled_lines(text, theme.overlay_quiet(), width)) {
    Ok(line) -> line
    Error(Nil) -> span.line_new([])
  }
}

fn card_lines(text: String, width: Int) -> List(span.Line) {
  text
  |> styled_lines(style.new(theme.paper, theme.raised, style.none()), width)
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

fn styled_lines(
  text: String,
  appearance: style.Style,
  width: Int,
) -> List(span.Line) {
  text
  |> string.split("\n")
  |> list.map(fn(line) { span.line_new([span.span_styled(line, appearance)]) })
  |> span.text_new
  |> span.wrap(width)
  |> fn(wrapped) { wrapped.lines }
}

fn status_style(status: goal_view.Status) -> style.Style {
  case status {
    goal_view.Active -> theme.overlay_current()
    goal_view.Paused(..) | goal_view.Limited(..) -> theme.overlay_signal()
    goal_view.Complete -> style.new(theme.added, theme.graphite, style.bold())
  }
}

fn check_style(status: Option(Int)) -> style.Style {
  case status {
    Some(0) -> style.new(theme.added, theme.graphite, style.bold())
    Some(_) -> style.new(theme.danger, theme.graphite, style.bold())
    None -> theme.overlay_signal()
  }
}

fn duration(milliseconds: Int) -> String {
  let seconds = int.max(0, milliseconds) / 1000
  case seconds {
    value if value < 60 -> int.to_string(value) <> "s"
    value if value < 3600 -> int.to_string(value / 60) <> "m"
    value -> int.to_string(value / 3600) <> "h"
  }
}

fn money(value: Float) -> String {
  let cents = int.max(0, float.round(value *. 100.0))
  "$"
  <> int.to_string(cents / 100)
  <> "."
  <> string.pad_start(int.to_string(cents % 100), 2, "0")
}
