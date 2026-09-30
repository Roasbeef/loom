//// The agent strip: one row per live agent, pinned under the footer, so an
//// operator running several strands at once can see what each is doing
//// without opening anything.
////
//// The `/agents` workspace answers every question about a strand, but only
//// once the operator goes looking. The strip answers the one question asked
//// most often, "what is everybody doing right now", from the corner of the
//// eye. It grows by a row as each agent starts, and drops a row when an agent
//// settles, so its height is itself a count of the work in flight.
////
//// Which strands are listed, in what order, and what words, elapsed time and
//// context size each shows are `session_view/agent_roster`'s, which the web
//// view's agent chips read too. This module keeps what is the terminal's
//// own: the rows it paints and the keyboard focus that moves between them.
////
//// Keyboard focus is a separate small state machine. Down from an idle
//// composer moves a cursor into the strip; Up and Down move it; Enter opens
//// the selected strand (the transcript and the composer's recipient switch
//// together, through the same path the workspace's Enter uses); `x` stops
//// the selected strand's operation; Escape, or Up past the first row, hands
//// the keyboard back. Moving the cursor never retargets the composer, so an
//// unsent draft can never be redirected to an agent by browsing.

import etui/buffer
import etui/geometry.{type Rect}
import etui/span
import etui/style
import etui/text
import etui/widgets/paragraph
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import session_view/agent_roster
import session_view/agent_view
import session_view/snapshot_view
import session_view/text_hygiene
import tui/agents
import tui/theme

/// The most agent rows the strip draws before it folds the rest into a count.
@internal
pub const max_rows = 8

/// The shortest terminal the strip appears on. Below this the transcript and
/// editor keep every row, and the footer's agent count remains the summary.
@internal
pub const min_screen_height = 16

/// Who owns the keyboard: the composer, or the strip with its cursor on one
/// strand. The cursor is a strand ID rather than an index, so a row arriving
/// or leaving above it cannot move the selection to a different agent.
@internal
pub type Focus {
  /// The composer has the keyboard; the strip only displays.
  Composing

  /// The strip has the keyboard and the cursor rests on `cursor`.
  Browsing(cursor: String)
}

/// Everything the strip remembers between captures: who owns the keyboard,
/// and the roster's own memory of glances, clocks and pushed usage.
@internal
pub type State {
  State(
    /// Keyboard ownership and the cursor.
    focus: Focus,
    /// What `agent_roster` remembers between captures.
    roster: agent_roster.Roster,
  )
}

/// One drawn row: `agent_roster`'s line for one agent.
@internal
pub type Line =
  agent_roster.Line

/// What a key pressed while the strip has focus asks for.
@internal
pub type Outcome {
  /// The cursor moved, or nothing changed; the strip keeps the keyboard.
  Moved(State)

  /// The keyboard returns to the composer and the key is consumed.
  Left(State)

  /// Open this strand: switch the transcript and the composer's recipient.
  Open(State, strand: String)

  /// Stop this strand's running operation.
  Stop(State, strand: String)

  /// The keyboard returns to the composer, which should handle this key.
  Pass(State)
}

/// A strip with nothing observed and the composer holding the keyboard.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.new().focus == agent_strip.Composing
/// ```
@internal
pub fn new() -> State {
  State(focus: Composing, roster: agent_roster.new())
}

/// Folds one coherent capture into the strip's memory
/// (`agent_roster.observe`).
///
/// ## Examples
///
/// ```gleam
/// // agent_strip.observe(state, view, model.stamp.now_ms)
/// ```
@internal
pub fn observe(state: State, view: snapshot_view.View, now_ms: Int) -> State {
  State(..state, roster: agent_roster.observe(state.roster, view, now_ms))
}

/// Records a live usage push as the operation's current context size
/// (`agent_roster.observe_usage`).
///
/// ## Examples
///
/// ```gleam
/// // agent_strip.observe_usage(state, "sub:main/x", Some("op"), usage)
/// ```
@internal
pub fn observe_usage(
  state: State,
  strand: String,
  operation: Option(String),
  context: Int,
) -> State {
  State(
    ..state,
    roster: agent_roster.observe_usage(state.roster, strand, operation, context),
  )
}

/// Advances the strip's clock on the tick, reporting whether a drawn second
/// changed (`agent_roster.tick`).
///
/// ## Examples
///
/// ```gleam
/// let #(_, moved) = agent_strip.tick(agent_strip.new(), 0)
/// assert moved == agent_roster.Unchanged
/// ```
@internal
pub fn tick(state: State, now_ms: Int) -> #(State, agent_roster.Repaint) {
  let #(roster, repaint) = agent_roster.tick(state.roster, now_ms)
  #(State(..state, roster:), repaint)
}

/// Projects the rows the strip draws, in stable roster order
/// (`agent_roster.lines`).
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.lines(agent_strip.new(), [], "main") == []
/// ```
@internal
pub fn lines(
  state: State,
  rows: List(agent_view.Row),
  active: String,
) -> List(Line) {
  agent_roster.lines(state.roster, rows, active)
}

/// Whether the strip is drawn: only when there is a second agent to watch.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.visible([]) == False
/// ```
@internal
pub fn visible(lines: List(Line)) -> Bool {
  agent_roster.visible(lines)
}

/// The rows the strip takes on a screen, including its overflow row.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.height([], 40) == 0
/// ```
@internal
pub fn height(lines: List(Line), screen_height: Int) -> Int {
  height_for_count(list.length(lines), screen_height)
}

/// The strip's height from its membership count, including overflow.
///
/// A geometry query has no use for formatted lines. Painting and hit testing
/// use this same bound whether they already hold lines or only the roster.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.height_for_count(1, 40) == 0
/// assert agent_strip.height_for_count(12, 40) == 8
/// ```
@internal
pub fn height_for_count(count: Int, screen_height: Int) -> Int {
  case count >= 2 && screen_height >= min_screen_height {
    False -> 0
    True -> int.min(count, capacity(screen_height))
  }
}

// A quarter of the screen, between two rows and `max_rows`, so a burst of
// agents cannot push the transcript off a small terminal.
fn capacity(screen_height: Int) -> Int {
  int.clamp(screen_height / 4, min: 2, max: max_rows)
}

/// Moves the keyboard into the strip, with the cursor on the row after the
/// strand being viewed, which is the agent a Down press most plausibly means.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.enter(agent_strip.new(), [], "main").focus
///   == agent_strip.Composing
/// ```
@internal
pub fn enter(state: State, lines: List(Line), active: String) -> State {
  let ids = list.map(lines, fn(line) { line.id })
  let after =
    ids
    |> list.drop_while(fn(id) { id != active })
    |> list.drop(1)
    |> list.first
  case after, ids {
    Ok(id), _ | Error(Nil), [id, ..] -> State(..state, focus: Browsing(id))
    Error(Nil), [] -> state
  }
}

/// Hands the keyboard back to the composer, keeping everything observed.
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.leave(agent_strip.new()).focus == agent_strip.Composing
/// ```
@internal
pub fn leave(state: State) -> State {
  State(..state, focus: Composing)
}

/// Answers one key while the strip holds the keyboard.
///
/// ## Examples
///
/// ```gleam
/// // agent_strip.key(state, keys.Enter, lines)
/// ```
@internal
pub fn key(state: State, pressed: StripKey, lines: List(Line)) -> Outcome {
  case state.focus {
    Composing -> Pass(state)
    Browsing(cursor) -> browse(state, pressed, lines, cursor)
  }
}

/// The keys the strip distinguishes; everything else hands back the keyboard.
@internal
pub type StripKey {
  /// Moves the cursor toward the top, or out of the strip from its top row.
  Up

  /// Moves the cursor toward the bottom.
  Down

  /// Opens the strand under the cursor.
  Select

  /// Stops the operation of the strand under the cursor.
  Halt

  /// Returns the keyboard to the composer.
  Back

  /// Any other key: returned to the composer to handle.
  Other
}

fn browse(
  state: State,
  pressed: StripKey,
  lines: List(Line),
  cursor: String,
) -> Outcome {
  let ids = list.map(lines, fn(line) { line.id })
  let composing = State(..state, focus: Composing)

  // A cursor whose strand has left the strip is re-seated on the first row
  // rather than acting on an agent the operator can no longer see.
  let cursor = case list.contains(ids, cursor), ids {
    True, _ -> Ok(cursor)
    False, [first, ..] -> Ok(first)
    False, [] -> Error(Nil)
  }
  case cursor, pressed {
    Error(Nil), _ -> Left(composing)
    Ok(_), Back -> Left(composing)
    Ok(_), Other -> Pass(composing)
    Ok(id), Select -> Open(composing, id)
    Ok(id), Halt -> Stop(State(..state, focus: Browsing(id)), id)
    Ok(id), Down -> Moved(State(..state, focus: Browsing(step(ids, id, 1))))
    Ok(id), Up ->
      case list.first(ids) == Ok(id) {
        True -> Left(composing)
        False -> Moved(State(..state, focus: Browsing(step(ids, id, -1))))
      }
  }
}

fn step(ids: List(String), from: String, by: Int) -> String {
  let indexed = list.index_map(ids, fn(id, index) { #(index, id) })
  let at =
    list.find(indexed, fn(pair) { pair.1 == from })
    |> result.map(fn(pair) { pair.0 })
    |> result.unwrap(0)
  let target = int.clamp(at + by, min: 0, max: list.length(ids) - 1)
  list.find(indexed, fn(pair) { pair.0 == target })
  |> result.map(fn(pair) { pair.1 })
  |> result.unwrap(from)
}

/// The composer badge naming the viewed agent's task, when it has one
/// (`agent_roster.badge`).
///
/// ## Examples
///
/// ```gleam
/// assert agent_strip.badge([], "main") == None
/// ```
@internal
pub fn badge(lines: List(Line), active: String) -> Option(String) {
  agent_roster.badge(lines, active)
}

/// Paints the strip into its area, bottom-aligned under the footer.
///
/// ## Examples
///
/// ```gleam
/// // agent_strip.render(buf, area, lines, state.focus, "main")
/// ```
@internal
pub fn render(
  buf: buffer.Buffer,
  area: Rect,
  lines: List(Line),
  focus: Focus,
  active: String,
) -> buffer.Buffer {
  let capacity = area.size.height
  let overflow = list.length(lines) - capacity
  let shown = case overflow > 0 {
    True -> window(lines, focus, capacity - 1)
    False -> lines
  }
  let rows =
    list.map(shown, fn(line) { row(line, focus, active, area.size.width) })
  let rows = case overflow > 0 {
    False -> rows
    True ->
      list.append(rows, [
        span.line_new([
          span.span_styled(
            text.pad_right(
              "  +"
                <> int.to_string(list.length(lines) - list.length(shown))
                <> " more · ^O agents",
              area.size.width,
            ),
            theme.quiet_text(),
          ),
        ]),
      ])
  }
  paragraph.render_styled(buf, area, rows)
}

// When the rows outnumber the space, the window follows the cursor so the
// selected agent is always drawn; otherwise it shows the top of the roster.
fn window(lines: List(Line), focus: Focus, size: Int) -> List(Line) {
  let at = case focus {
    Composing -> 0
    Browsing(cursor) ->
      list.index_map(lines, fn(line, index) { #(index, line.id) })
      |> list.find(fn(pair) { pair.1 == cursor })
      |> result.map(fn(pair) { pair.0 })
      |> result.unwrap(0)
  }
  let start = int.clamp(at - size + 1, min: 0, max: list.length(lines))
  lines |> list.drop(start) |> list.take(size)
}

fn row(line: Line, focus: Focus, active: String, width: Int) -> span.Line {
  let selected = focus == Browsing(line.id)
  let viewing = line.id == active
  let background = case selected {
    True -> theme.raised
    False -> style.Default
  }

  // The cursor and the viewed strand each carry a mark as well as a color,
  // so the strip still reads on a terminal with no color at all.
  let cursor = case selected, viewing {
    True, _ -> "❯ "
    False, True -> "› "
    False, False -> "  "
  }

  // The meter keeps its column; on a narrow terminal it goes first, since
  // what the agent is doing matters more than for how long.
  let meter = case width >= 72 {
    True -> meter(line)
    False -> ""
  }
  let name_width = int.min(22, int.max(8, width / 5))
  let name = text.pad_right(fit(line.name, name_width), name_width)
  let lead = cursor <> agents.status_mark(line.status) <> " "
  let room =
    width - text.cell_width(lead) - name_width - 1 - text.cell_width(meter) - 1
  let body = text.pad_right(fit(line.text, room), int.max(0, room))
  let name_style = case viewing {
    True -> style.new(theme.signal, background, style.bold())
    False -> style.new(theme.current, background, style.none())
  }
  span.line_new([
    span.span_styled(cursor, style.new(theme.signal, background, style.bold())),
    span.span_styled(
      agents.status_mark(line.status) <> " ",
      agents.status_style(line.status, background),
    ),
    span.span_styled(name <> " ", name_style),
    span.span_styled(
      body <> " ",
      style.new(theme.paper, background, style.none()),
    ),
    span.span_styled(meter, style.new(theme.quiet, background, style.none())),
  ])
}

fn meter(line: Line) -> String {
  let time = option.map(line.elapsed_s, agent_roster.duration)
  let size =
    option.map(line.tokens, fn(count) {
      agent_roster.count_label(count) <> " ctx"
    })
  case time, size {
    Some(time), Some(size) -> time <> " · " <> size
    Some(one), None | None, Some(one) -> one
    None, None -> ""
  }
}

fn fit(value: String, width: Int) -> String {
  text.truncate(text_hygiene.single_line(value), int.max(0, width), "…")
}
